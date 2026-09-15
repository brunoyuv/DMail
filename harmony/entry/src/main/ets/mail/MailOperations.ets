// MPL-2.0: https://mozilla.org/MPL/2.0/
import { util } from '@kit.ArkTS';
import { AccountStore } from '../data/AccountStore';
import { JmapEmail, JmapKeyword, JmapService, JmapError, JmapArchiveUndo, JmapMailbox, shallowCopyEmail } from './jmap/JmapClient';

interface PendingKeyword {
  accountId: string; mail: JmapEmail; keyword: JmapKeyword; enabled: boolean;
}
interface PendingMove { accountId: string; mail: JmapEmail; mailboxIds: string[]; undo?: JmapArchiveUndo; action?: string; }
interface CompletedMove { accountId: string; undo: JmapArchiveUndo; }
interface OperationNotice { accountId: string; emailId: string; label: string; }

// Jobs own their captured account and service. UI navigation does not cancel a
// server mutation or discard its acknowledgement. Never replay an uncertain
// operation automatically after process termination.
export class MailOperations {
  private static jobs: Map<string, PendingKeyword> = new Map();
  private static notices: OperationNotice[] = [];
  private static moves: Map<string, PendingMove> = new Map();
  private static undoRecords: CompletedMove[] = [];
  private static folderRevisions: Map<string, number> = new Map();
  static mailboxRevision(accountId: string): number { return MailOperations.folderRevisions.get(accountId) || 0; }
  private static confirmedIdentities: Map<string, string> = new Map();
  static currentEmailId(accountId: string, emailId: string): string {
    return MailOperations.confirmedIdentities.get(MailOperations.key(accountId, emailId)) || emailId;
  }
  private static rememberIdentity(accountId: string, oldId: string, newId: string): void {
    // Flatten prior links for an open reader that spans Archive and Undo. This
    // bounded process-local map contains confirmed cache acknowledgements only.
    const prefix = `${accountId}:`;
    for (const key of Array.from(MailOperations.confirmedIdentities.keys())) {
      if (key.startsWith(prefix) && MailOperations.confirmedIdentities.get(key) === oldId) {
        MailOperations.confirmedIdentities.set(key, newId);
      }
    }
    const key = MailOperations.key(accountId, oldId);
    MailOperations.confirmedIdentities.delete(key);
    MailOperations.confirmedIdentities.set(key, newId);
    const expired = Array.from(MailOperations.confirmedIdentities.keys()).slice(0, Math.max(0, MailOperations.confirmedIdentities.size - 128));
    for (const stale of expired) { MailOperations.confirmedIdentities.delete(stale); }
  }
  private static idleWaiters: Array<() => void> = [];
  static whenIdle(): Promise<void> {
    return MailOperations.jobs.size + MailOperations.moves.size === 0 ? Promise.resolve() : new Promise<void>(resolve => MailOperations.idleWaiters.push(resolve));
  }
  private static key(accountId: string, emailId: string): string { return `${accountId}:${emailId}`; }
  private static changed(): void {
    AppStorage.setOrCreate('mailOperationRevision', (AppStorage.get<number>('mailOperationRevision') || 0) + 1);
  }
  static pending(accountId: string, emailId: string): boolean { return MailOperations.jobs.has(MailOperations.key(accountId, emailId)) || MailOperations.moves.has(MailOperations.key(accountId, emailId)); }
  static pendingEmailIds(accountId: string): string[] {
    return Array.from(new Set(Array.from(MailOperations.jobs.values()).filter(job => job.accountId === accountId).map(job => job.mail.id)
      .concat(Array.from(MailOperations.moves.values()).filter(job => job.accountId === accountId).map(job => job.mail.id))));
  }
  static count(accountId: string): number { return Array.from(MailOperations.jobs.values()).filter(job => job.accountId === accountId).length + Array.from(MailOperations.moves.values()).filter(job => job.accountId === accountId).length; }
  static notice(accountId: string): string { return MailOperations.notices.find(notice => notice.accountId === accountId)?.label || ''; }
  static clearNotices(accountId: string): void { MailOperations.notices = MailOperations.notices.filter(notice => notice.accountId !== accountId); }
  static overlay(accountId: string, mail: JmapEmail): JmapEmail {
    const move = MailOperations.moves.get(MailOperations.key(accountId, mail.id));
    if (move) {
      const copy = shallowCopyEmail(mail); copy.mailboxIds = move.mailboxIds.slice(); return copy;
    }
    const job = MailOperations.jobs.get(MailOperations.key(accountId, mail.id));
    if (!job) { return mail; }
    // Bodies are immutable strings. A flag projection only needs its own
    // keyword array, not JSON encoding/parsing of the whole cached message.
    const copy = shallowCopyEmail(mail);
    copy.keywords = mail.keywords.filter(value => value !== job.keyword);
    if (job.enabled) { copy.keywords.push(job.keyword); }
    return copy;
  }
  static setKeyword(store: AccountStore, client: JmapService, accountId: string, serverId: string,
    mail: JmapEmail, keyword: JmapKeyword): void {
    const key = MailOperations.key(accountId, mail.id);
    if (MailOperations.pending(accountId, mail.id)) { return; }
    const job: PendingKeyword = { accountId, mail, keyword, enabled: !mail.keywords.includes(keyword) };
    MailOperations.jobs.set(key, job);
    MailOperations.notices = MailOperations.notices.filter(notice => notice.accountId !== accountId || notice.emailId !== mail.id);
    MailOperations.changed();
    MailOperations.perform(store, client, serverId, job);
  }
  static undo(accountId: string): JmapArchiveUndo | null { return MailOperations.undoRecords.find(record => record.accountId === accountId)?.undo || null; }
  static move(store: AccountStore, client: JmapService, accountId: string, serverId: string,
    mail: JmapEmail, mailboxIds: string[], undo?: JmapArchiveUndo, action: string = 'archive'): void {
    if (MailOperations.pending(accountId, mail.id)) { return; }
    const job: PendingMove = { accountId, mail, mailboxIds, undo, action: undo?.action || action };
    MailOperations.moves.set(MailOperations.key(accountId, mail.id), job);
    MailOperations.undoRecords = MailOperations.undoRecords.filter(record => record.accountId !== accountId);
    MailOperations.notices = MailOperations.notices.filter(notice => notice.accountId !== accountId || notice.emailId !== mail.id);
    MailOperations.changed(); MailOperations.performMove(store, client, serverId, job);
  }
  private static async performMove(store: AccountStore, client: JmapService, serverId: string, job: PendingMove): Promise<void> {
    let requested = false;
    try {
      if (!await store.mail.beginMutation(job.accountId, job.mail.id)) { throw new JmapError('changeUnconfirmed'); }
      requested = true;
      let destinationId = job.mail.id;
      let undoRecord: JmapArchiveUndo | null = null;
      let archiveMailbox: JmapMailbox | undefined = undefined;
      if (job.undo) {
        const movedId = await client.undoArchive(job.undo);
        if (job.undo.imap === true) { destinationId = movedId || `local_archive_${util.generateRandomUUID()}`; }
      } else {
        if (job.action === 'delete' && !client.deleteEmail) { throw new JmapError('archiveUnavailable'); }
        const undo = job.action === 'delete' ? await client.deleteEmail!(serverId, job.mail.id) : await client.archiveEmail(serverId, job.mail.id);
        job.mailboxIds = undo.expectedMailboxIds.slice();
        archiveMailbox = undo.imap === true ? undo.archiveMailbox : undefined;
        if (undo.imap === true) { destinationId = undo.movedEmailId || `local_archive_${util.generateRandomUUID()}`; }
        if (undo.canUndo !== false) {
          undoRecord = { accountId: undo.accountId, emailId: destinationId, inboxId: undo.inboxId,
            archiveId: undo.archiveId, addedArchive: undo.addedArchive, expectedMailboxIds: undo.expectedMailboxIds.slice(),
            canUndo: undo.canUndo, imap: undo.imap, action: job.action };
        }
      }
      if (destinationId !== job.mail.id) {
        if (archiveMailbox) {
          await store.mail.moveEmailIdentity(job.accountId, job.mail.id, destinationId, job.mailboxIds, archiveMailbox);
          MailOperations.folderRevisions.set(job.accountId, MailOperations.mailboxRevision(job.accountId) + 1);
        } else { await store.mail.moveEmailIdentity(job.accountId, job.mail.id, destinationId, job.mailboxIds); }
        MailOperations.rememberIdentity(job.accountId, job.mail.id, destinationId);
      } else { await store.mail.updateMailboxes(job.accountId, job.mail.id, job.mailboxIds); }
      if (undoRecord) { MailOperations.undoRecords.push({ accountId: job.accountId, undo: undoRecord }); }
      MailOperations.notices.push({ accountId: job.accountId, emailId: destinationId, label: job.action === 'delete' ? (job.undo ? 'delete_undone' : 'message_deleted') : (job.undo ? 'archive_undone' : 'message_archived') });
    } catch (error) {
      const code = (error as JmapError).code;
      const refused = ['forbidden', 'accountReadOnly', 'archiveUnavailable'].includes(code);
      if (refused) { await store.mail.updateMailboxes(job.accountId, job.mail.id, job.mail.mailboxIds).catch(() => {}); }
      MailOperations.notices.push({ accountId: job.accountId, emailId: job.mail.id, label: !requested ? (code === 'changeUnconfirmed' ? 'change_unconfirmed' : 'cache_save_error') :
        code === 'stateMismatch' ? 'move_conflict' : code === 'archiveUnavailable' && job.action === 'delete' ? 'trash_unavailable' : refused ? 'change_forbidden' : 'change_unconfirmed' });
    } finally {
      store.mail.endMutation(job.accountId, job.mail.id);
      MailOperations.moves.delete(MailOperations.key(job.accountId, job.mail.id)); MailOperations.changed();
      if (MailOperations.jobs.size + MailOperations.moves.size === 0) { MailOperations.idleWaiters.splice(0).forEach(resolve => resolve()); }
    }
  }
  private static async perform(store: AccountStore, client: JmapService, serverId: string, job: PendingKeyword): Promise<void> {
    let requested = false;
    try {
      if (!await store.mail.beginMutation(job.accountId, job.mail.id)) { throw new JmapError('changeUnconfirmed'); }
      requested = true;
      await client.setKeyword(serverId, job.mail.id, job.keyword, job.enabled);
      // Acknowledgement persists even if the originating view/account changed.
      await store.mail.updateKeyword(job.accountId, job.mail.id, job.keyword, job.enabled, true);
    } catch (error) {
      const code = (error as JmapError).code;
      const refused = code === 'forbidden' || code === 'accountReadOnly';
      if (refused) {
        await store.mail.updateKeyword(job.accountId, job.mail.id, job.keyword, !job.enabled).catch(() => {});
      }
      MailOperations.notices.push({ accountId: job.accountId, emailId: job.mail.id,
        label: !requested ? (code === 'changeUnconfirmed' ? 'change_unconfirmed' : 'cache_save_error') : refused ? 'change_forbidden' :
          code === 'messageNotFound' ? 'message_removed' : 'change_unconfirmed' });
    } finally {
      store.mail.endMutation(job.accountId, job.mail.id);
      MailOperations.jobs.delete(MailOperations.key(job.accountId, job.mail.id)); MailOperations.changed();
      if (MailOperations.jobs.size + MailOperations.moves.size === 0) { MailOperations.idleWaiters.splice(0).forEach(resolve => resolve()); }
    }
  }
}
