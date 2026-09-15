// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore } from '../data/AccountStore';
import { JmapEmail } from './jmap/JmapClient';
import { MailOperations } from './MailOperations';

interface UnreadMailboxSnapshot { id: string; inbox: boolean; emails: JmapEmail[]; }
interface UnreadAccountSnapshot { accountId: string; mailboxes: UnreadMailboxSnapshot[]; }
interface UnreadMailboxStatus { id: string; inbox: boolean; unread: boolean; }
interface UnreadAccountStatus { accountId: string; mailboxes: UnreadMailboxStatus[]; }

// The encrypted mailbox views are the durable source. A dot means that at
// least one downloaded member is unread; it is never a partial server count.
// Retained message bodies outside a current view do not create unread ghosts.
export class MailUnreadStatus {
  private static values: UnreadAccountStatus[] = [];
  private static refreshing: number = 0;
  private static changeRevision: number = 0;

  static revision(): number { return MailUnreadStatus.changeRevision; }
  static hasUnread(accountId: string, mailboxId?: string): boolean {
    const account = MailUnreadStatus.values.find(value => value.accountId === accountId);
    return account?.mailboxes.some(mailbox => (mailboxId === undefined ? mailbox.inbox : mailbox.id === mailboxId) && mailbox.unread) === true;
  }
  static anyInboxUnread(): boolean {
    return MailUnreadStatus.values.some(account => account.mailboxes.some(mailbox => mailbox.inbox && mailbox.unread));
  }

  static async refresh(store: AccountStore): Promise<void> {
    const revision = ++MailUnreadStatus.refreshing;
    const accounts = await store.list();
    const snapshots: UnreadAccountSnapshot[] = [];
    const failedAccounts: string[] = [];
    for (const account of accounts) {
      if (revision !== MailUnreadStatus.refreshing) { return; }
      try {
        const boxes = await store.mail.boxes(account.id);
        const mailboxes: UnreadMailboxSnapshot[] = [];
        for (const box of boxes?.boxes || []) {
          if (revision !== MailUnreadStatus.refreshing) { return; }
          const view = await store.mail.view(account.id, box.id, true, false);
          const mailbox: UnreadMailboxSnapshot = { id: box.id, inbox: box.role === 'inbox', emails: view?.emails || [] };
          mailboxes.push(mailbox);
        }
        const snapshot: UnreadAccountSnapshot = { accountId: account.id, mailboxes };
        snapshots.push(snapshot);
      } catch (_) { failedAccounts.push(account.id); }
    }
    if (revision !== MailUnreadStatus.refreshing) { return; }
    const values: UnreadAccountStatus[] = [];
    for (const account of snapshots) {
      // Pending moves may add a member to another already-cached mailbox before
      // acknowledgement inserts it into that destination's persisted view.
      // Project each snapshot at most once instead of appending the pending
      // snapshots to every folder. Different snapshots of one ID still OR
      // together; no deduplication can discard an observed unread member.
      const mailboxes = account.mailboxes.map((mailbox): UnreadMailboxStatus => ({
        id: mailbox.id, inbox: mailbox.inbox, unread: false
      }));
      const byId = new Map<string, UnreadMailboxStatus>();
      for (const mailbox of mailboxes) { byId.set(mailbox.id, mailbox); }
      let remaining = mailboxes.length;
      const markUnread = (mailboxId: string): void => {
        const mailbox = byId.get(mailboxId);
        if (mailbox && !mailbox.unread) { mailbox.unread = true; remaining--; }
      };
      for (const source of account.mailboxes) {
        const mailbox = byId.get(source.id)!;
        for (const mail of source.emails) {
          if (remaining === 0) { break; }
          const pending = MailOperations.pending(account.accountId, mail.id);
          if (mailbox.unread && !pending) { continue; }
          const current = MailOperations.overlay(account.accountId, mail);
          if (current.keywords.includes('$seen')) { continue; }
          if (pending) {
            for (const id of current.mailboxIds) { markUnread(id); }
          } else if (current.mailboxIds.includes(source.id)) { markUnread(source.id); }
        }
        if (remaining === 0) { break; }
      }
      const status: UnreadAccountStatus = { accountId: account.accountId, mailboxes };
      values.push(status);
    }
    // A transient local read failure does not clear a known dot. Deleted
    // accounts are absent from the ready-account list and disappear normally.
    values.push(...MailUnreadStatus.values.filter(value => failedAccounts.includes(value.accountId)));
    values.sort((a, b) => a.accountId.localeCompare(b.accountId));
    for (const account of values) { account.mailboxes.sort((a, b) => a.id.localeCompare(b.id)); }
    if (JSON.stringify(values) !== JSON.stringify(MailUnreadStatus.values)) {
      MailUnreadStatus.values = values; ++MailUnreadStatus.changeRevision;
      AppStorage.setOrCreate('mailUnreadRevision', MailUnreadStatus.changeRevision);
    }
  }
}
