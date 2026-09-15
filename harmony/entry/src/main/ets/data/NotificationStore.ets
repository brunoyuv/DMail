// MPL-2.0: https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { NotificationAccountState, InboxCheck, validFrequencies } from '../mail/notifications/NotificationModel';
type Queue = (operation: () => Promise<void>) => Promise<void>;

// Separate from message retention and cache mutation. All queries join ready
// accounts, including late replies from another process after account removal.
export class NotificationStore {
  private db: relationalStore.RdbStore;
  private queue: Queue;
  constructor(db: relationalStore.RdbStore, queue: Queue) { this.db = db; this.queue = queue; }
  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS mail_notifications (notification_id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0, foreground_minutes INTEGER NOT NULL DEFAULT 5, background_minutes INTEGER NOT NULL DEFAULT 120, cursor TEXT NOT NULL DEFAULT \'\', mailbox_id TEXT NOT NULL DEFAULT \'\', last_attempt INTEGER NOT NULL DEFAULT 0, last_check INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, notice_version INTEGER NOT NULL DEFAULT 0, acknowledged_version INTEGER NOT NULL DEFAULT 0)');
    await db.executeSql('CREATE TABLE IF NOT EXISTS mail_check_lease (id INTEGER PRIMARY KEY, owner TEXT NOT NULL, expires INTEGER NOT NULL)');
  }
  private async read(accountId: string | null): Promise<NotificationAccountState[]> {
    const rows = await this.db.querySql("SELECT n.* FROM mail_notifications n JOIN accounts a ON a.id = n.account_id WHERE a.status = 'ready'" +
      (accountId === null ? ' ORDER BY n.last_attempt, n.notification_id' : ' AND n.account_id = ?'), accountId === null ? [] : [accountId]);
    const result: NotificationAccountState[] = [];
    try { while (rows.goToNextRow()) {
      const value = new NotificationAccountState();
      value.accountId = rows.getString(rows.getColumnIndex('account_id'));
      value.notificationId = rows.getLong(rows.getColumnIndex('notification_id'));
      value.enabled = rows.getLong(rows.getColumnIndex('enabled')) === 1;
      value.revision = rows.getLong(rows.getColumnIndex('revision'));
      value.foregroundMinutes = rows.getLong(rows.getColumnIndex('foreground_minutes'));
      value.backgroundMinutes = rows.getLong(rows.getColumnIndex('background_minutes'));
      value.cursor = rows.getString(rows.getColumnIndex('cursor'));
      value.mailboxId = rows.getString(rows.getColumnIndex('mailbox_id'));
      value.lastAttempt = rows.getLong(rows.getColumnIndex('last_attempt'));
      value.lastCheck = rows.getLong(rows.getColumnIndex('last_check'));
      value.failures = rows.getLong(rows.getColumnIndex('failures'));
      value.noticeVersion = rows.getLong(rows.getColumnIndex('notice_version'));
      value.acknowledgedVersion = rows.getLong(rows.getColumnIndex('acknowledged_version'));
      result.push(value);
    } } finally { rows.close(); }
    return result;
  }
  async list(): Promise<NotificationAccountState[]> {
    let values: NotificationAccountState[] = [];
    await this.queue(async () => { values = await this.read(null); }); return values;
  }
  async get(accountId: string): Promise<NotificationAccountState> {
    let values: NotificationAccountState[] = [];
    await this.queue(async () => { values = await this.read(accountId); });
    const result = values[0] || new NotificationAccountState(); result.accountId = accountId; return result;
  }
  configure(accountId: string, enabled: boolean): Promise<void> {
    return this.queue(async () => {
      await this.db.executeSql("INSERT OR IGNORE INTO mail_notifications (account_id) SELECT id FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
      // Only a changed toggle resets the baseline. Interval edits preserve it.
      await this.db.executeSql("UPDATE mail_notifications SET enabled = ?, revision = revision + 1, cursor = '', mailbox_id = '', last_attempt = 0, last_check = 0, failures = 0, acknowledged_version = notice_version WHERE account_id = ? AND enabled != ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
        [enabled ? 1 : 0, accountId, enabled ? 1 : 0, accountId]);
    });
  }
  frequencies(accountId: string, foreground: number, background: number): Promise<void> {
    if (!validFrequencies(foreground, background)) { return Promise.reject(new Error('Invalid checking interval')); }
    return this.queue(async () => {
      await this.db.executeSql("INSERT OR IGNORE INTO mail_notifications (account_id) SELECT id FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
      await this.db.executeSql('UPDATE mail_notifications SET foreground_minutes = ?, background_minutes = ?, revision = revision + 1 WHERE account_id = ?', [foreground, background, accountId]);
    });
  }
  async complete(accountId: string, revision: number, check: InboxCheck | null, now: number): Promise<boolean> {
    let accepted = false;
    await this.queue(async () => {
      this.db.beginTransaction();
      try {
        const current = (await this.read(accountId))[0];
        if (current?.enabled && current.revision === revision) {
          if (check) {
            if (!check.state || check.state.length > 2100000 || check.mailboxId.length > 4096 ||
              !Number.isInteger(check.newMessages) || check.newMessages < 0 || check.newMessages > 500) { throw new Error('Invalid inbox checkpoint'); }
            await this.db.executeSql('UPDATE mail_notifications SET cursor = ?, mailbox_id = ?, last_attempt = ?, last_check = ?, failures = 0, notice_version = notice_version + ? WHERE account_id = ?',
              [check.state, check.mailboxId, now, now, current.cursor !== '' && check.newMessages > 0 ? 1 : 0, accountId]);
          } else {
            await this.db.executeSql('UPDATE mail_notifications SET last_attempt = ?, failures = MIN(5, failures + 1) WHERE account_id = ?', [now, accountId]);
          }
          accepted = true;
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    }); return accepted;
  }
  acknowledge(accountId: string, noticeVersion: number): Promise<void> {
    return this.queue(() => this.db.executeSql('UPDATE mail_notifications SET acknowledged_version = ? WHERE account_id = ? AND enabled = 1 AND notice_version = ?', [noticeVersion, accountId, noticeVersion]));
  }
  async acquire(owner: string, now: number): Promise<boolean> {
    let acquired = false;
    await this.queue(async () => {
      this.db.beginTransaction();
      try {
        await this.db.executeSql("INSERT OR IGNORE INTO mail_check_lease (id, owner, expires) VALUES (1, '', 0)");
        await this.db.executeSql('UPDATE mail_check_lease SET owner = ?, expires = ? WHERE id = 1 AND (expires <= ? OR expires > ?)', [owner, now + 150000, now, now + 150000]);
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
      // Native querySql can use a pooled read connection. Inspect ownership
      // only after the conditional lease write is committed and visible.
      const rows = await this.db.querySql('SELECT owner FROM mail_check_lease WHERE id = 1');
      try { acquired = rows.goToFirstRow() && rows.getString(0) === owner; } finally { rows.close(); }
    });
    return acquired;
  }
  release(owner: string): Promise<void> {
    return this.queue(() => this.db.executeSql('DELETE FROM mail_check_lease WHERE id = 1 AND owner = ?', [owner]));
  }
}
