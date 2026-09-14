// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore } from '../data/AccountStore';
import { JmapEmail, JmapKeyword, JmapService, JmapError, JmapArchiveUndo } from './jmap/JmapClient';

interface PendingKeyword {
  accountId: string; mail: JmapEmail; keyword: JmapKeyword; enabled: boolean;
}
interface PendingMove { accountId: string; mail: JmapEmail; mailboxIds: string[]; undo?: JmapArchiveUndo; }
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
      const copy = JSON.parse(JSON.stringify(mail)) as JmapEmail; copy.mailboxIds = move.mailboxIds.slice(); return copy;
    }
    const job = MailOperations.jobs.get(MailOperations.key(accountId, mail.id));
    if (!job) { return mail; }
    const copy = JSON.parse(JSON.stringify(mail)) as JmapEmail;
    copy.keywords = copy.keywords.filter(value => value !== job.keyword);
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
    mail: JmapEmail, mailboxIds: string[], undo?: JmapArchiveUndo): void {
    if (MailOperations.pending(accountId, mail.id)) { return; }
    const job: PendingMove = { accountId, mail, mailboxIds, undo };
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
      if (job.undo) { await client.undoArchive(job.undo); }
      else {
        const undo = await client.archiveEmail(serverId, job.mail.id);
        job.mailboxIds = undo.expectedMailboxIds.slice();
        MailOperations.undoRecords.push({ accountId: job.accountId, undo });
      }
      await store.mail.updateMailboxes(job.accountId, job.mail.id, job.mailboxIds);
      MailOperations.notices.push({ accountId: job.accountId, emailId: job.mail.id, label: job.undo ? 'archive_undone' : 'message_archived' });
    } catch (error) {
      const code = (error as JmapError).code;
      const refused = ['forbidden', 'accountReadOnly', 'archiveUnavailable'].includes(code);
      if (refused) { await store.mail.updateMailboxes(job.accountId, job.mail.id, job.mail.mailboxIds).catch(() => {}); }
      MailOperations.notices.push({ accountId: job.accountId, emailId: job.mail.id, label: !requested ? (code === 'changeUnconfirmed' ? 'change_unconfirmed' : 'cache_save_error') :
        code === 'stateMismatch' ? 'move_conflict' : refused ? 'change_forbidden' : 'change_unconfirmed' });
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
