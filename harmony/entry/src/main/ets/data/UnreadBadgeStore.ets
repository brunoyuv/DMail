// MPL-2.0: https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { rdbTextProjection, readRdbText, RDB_TEXT_INLINE_BYTES } from './RdbText';
import { JmapEmail } from '../mail/jmap/JmapClient';
import { cacheIsFresh, decodeCachedBoxes, decodeCachedEmail } from './MailCacheModel';

type Queue = (operation: () => Promise<void>) => Promise<void>;
export type UnreadBadgeOverlay = (accountId: string, mail: JmapEmail) => JmapEmail;
export interface UnreadBadgeGuard { revision: number; settingsRevision: number; }
interface BadgeAccount { accountId: string; revision: number; settingsRevision: number; unread: number; mailboxId: string; }

// Exact server Inbox totals are independent of the retained message window.
// A bounded UID/FLAGS sample must never be stored as an unread total.
export class UnreadBadgeStore {
  private db: relationalStore.RdbStore;
  private queue: Queue;
  private available: boolean;
  constructor(db: relationalStore.RdbStore, queue: Queue, available: boolean = true) {
    this.db = db; this.queue = queue; this.available = available;
  }
  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql("CREATE TABLE IF NOT EXISTS mail_unread_badges (account_id TEXT PRIMARY KEY, revision INTEGER NOT NULL DEFAULT 0, unread_count INTEGER NOT NULL DEFAULT -1, mailbox_id TEXT NOT NULL DEFAULT '', checked_at INTEGER NOT NULL DEFAULT 0)");
  }
  private async ensure(accountId: string): Promise<void> {
    await this.db.executeSql("INSERT OR IGNORE INTO mail_unread_badges (account_id) SELECT id FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
  }
  private async accounts(accountId?: string): Promise<BadgeAccount[]> {
    const rows = await this.db.querySql("SELECT a.id, n.revision, COALESCE(b.revision, 0), COALESCE(b.unread_count, -1), COALESCE(b.mailbox_id, '') FROM accounts a JOIN mail_notifications n ON n.account_id = a.id LEFT JOIN mail_unread_badges b ON b.account_id = a.id WHERE a.status = 'ready' AND n.enabled = 1" + (accountId === undefined ? ' ORDER BY a.id' : ' AND a.id = ?'), accountId === undefined ? [] : [accountId]);
    const result: BadgeAccount[] = [];
    try { while (rows.goToNextRow()) {
      result.push({ accountId: rows.getString(0), settingsRevision: rows.getLong(1), revision: rows.getLong(2), unread: rows.getLong(3), mailboxId: rows.getString(4) });
    } } finally { rows.close(); }
    return result;
  }
  private async dirty(accountId: string): Promise<boolean> {
    const rows = await this.db.querySql("SELECT 1 FROM mail_cache WHERE account_id = ? AND kind = 'email' AND dirty != 0 LIMIT 1", [accountId]);
    try { return rows.goToFirstRow(); } finally { rows.close(); }
  }
  async beginCheck(accountId: string): Promise<UnreadBadgeGuard | null> {
    if (!this.available) { return null; }
    let guard: UnreadBadgeGuard | null = null;
    await this.queue(async () => {
      this.db.beginTransaction();
      try {
        await this.ensure(accountId);
        if (!await this.dirty(accountId)) {
          // Read the committed revision before incrementing it. Native RDB
          // querySql may use a pooled read connection that cannot see an
          // uncommitted UPDATE, unlike the single-connection host fixture.
          const current = (await this.accounts(accountId))[0];
          if (current) {
            await this.db.executeSql('UPDATE mail_unread_badges SET revision = revision + 1 WHERE account_id = ?', [accountId]);
            guard = { revision: current.revision + 1, settingsRevision: current.settingsRevision };
          }
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
    return guard;
  }
  record(accountId: string, guard: UnreadBadgeGuard | null, unreadEmails: number, mailboxId: string, checkedAt: number): Promise<void> {
    if (!this.available || guard === null) { return Promise.resolve(); }
    if (!Number.isSafeInteger(unreadEmails) || unreadEmails < 0 || mailboxId.length === 0 || mailboxId.length > 4096 || !Number.isSafeInteger(checkedAt) || checkedAt < 0) {
      return Promise.reject(new Error('Invalid unread count'));
    }
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const current = (await this.accounts(accountId))[0];
        if (current && current.revision === guard.revision && current.settingsRevision === guard.settingsRevision && !await this.dirty(accountId)) {
          await this.db.executeSql('UPDATE mail_unread_badges SET unread_count = ?, mailbox_id = ?, checked_at = ?, revision = revision + 1 WHERE account_id = ?', [unreadEmails, mailboxId, checkedAt, accountId]);
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
  }
  private async seed(value: BadgeAccount): Promise<void> {
    if (value.unread >= 0 || await this.dirty(value.accountId)) { return; }
    const rows = await this.db.querySql("SELECT payload FROM mail_cache WHERE account_id = ? AND kind = 'boxes' AND cache_key = '' AND dirty = 0", [value.accountId]);
    let payload = '';
    try { if (rows.goToFirstRow()) { payload = rows.getString(0); } } finally { rows.close(); }
    if (!payload) { return; }
    try {
      const cached = decodeCachedBoxes(payload);
      const inboxes = cached.boxes.filter(box => box.role === 'inbox');
      if (!cacheIsFresh(cached.savedAt) || inboxes.length !== 1 || inboxes[0].countsKnown === false) { return; }
      const inbox = inboxes[0];
      if (!Number.isSafeInteger(inbox.unreadEmails) || inbox.unreadEmails < 0) { return; }
      await this.ensure(value.accountId);
      await this.db.executeSql('UPDATE mail_unread_badges SET unread_count = ?, mailbox_id = ?, checked_at = ? WHERE account_id = ? AND unread_count < 0', [inbox.unreadEmails, inbox.id, cached.savedAt, value.accountId]);
      value.unread = inbox.unreadEmails; value.mailboxId = inbox.id;
    } catch (_) { /* Invalid or incomplete cache metadata is not a count. */ }
  }
  async total(overlay?: UnreadBadgeOverlay, pendingIds?: (accountId: string) => string[]): Promise<number | null> {
    if (!this.available) { return null; }
    let total: number | null = 0;
    await this.queue(async () => {
      this.db.beginTransaction();
      try {
        const accounts = await this.accounts();
        for (const account of accounts) {
          await this.seed(account);
          if (account.unread < 0) { total = null; break; }
          let count = account.unread;
          if (overlay && pendingIds) {
            for (const emailId of Array.from(new Set(pendingIds(account.accountId)))) {
              const query = "SELECT payload FROM mail_cache WHERE account_id = ? AND kind = 'email' AND cache_key = ?";
              const args: relationalStore.ValueType[] = [account.accountId, emailId];
              const rows = await this.db.querySql(`SELECT length(CAST(payload AS BLOB)), ${rdbTextProjection('payload')} FROM (${query})`, args);
              let bytes = 0, payload: string | null = null;
              try {
                if (!rows.goToFirstRow()) { continue; }
                bytes = rows.getLong(0); payload = rows.getString(1);
              } finally { rows.close(); }
              // New file-backed bodies keep this row small. Legacy cached
              // bodies still need bounded reads until their lazy migration.
              if (bytes > RDB_TEXT_INLINE_BYTES) { payload = await readRdbText(this.db, query, args, 8 * 1024 * 1024, bytes); }
              if (payload === null) { continue; }
              const cached = decodeCachedEmail(payload);
              const changed = overlay(account.accountId, cached.mail);
              count += UnreadBadgeStore.contribution(changed, account.mailboxId) - UnreadBadgeStore.contribution(cached.mail, account.mailboxId);
            }
          }
          total = (total ?? 0) + Math.max(0, count);
          if (!Number.isSafeInteger(total)) { total = null; break; }
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
    return total;
  }
  private static contribution(mail: JmapEmail | null, mailboxId: string): number {
    return mail !== null && mail.mailboxIds.includes(mailboxId) && !mail.keywords.includes('$seen') ? 1 : 0;
  }
  // The cache invokes these methods inside its existing queue/transaction.
  // Never enqueue recursively here: acknowledgement and count adjustment must
  // commit atomically, with old persisted flags as the comparison baseline.
  async mutationStarted(accountId: string): Promise<void> {
    if (!this.available) { return; }
    await this.ensure(accountId);
    const current = (await this.accounts(accountId))[0];
    if (current && current.unread < 0) { await this.seed(current); }
    await this.db.executeSql('UPDATE mail_unread_badges SET revision = revision + 1 WHERE account_id = ?', [accountId]);
  }
  async messageChanged(accountId: string, previous: JmapEmail | null, current: JmapEmail | null): Promise<void> {
    if (!this.available) { return; }
    await this.mutationStarted(accountId);
    const rows = await this.db.querySql('SELECT unread_count, mailbox_id FROM mail_unread_badges WHERE account_id = ?', [accountId]);
    let count = -1; let mailboxId = '';
    try { if (rows.goToFirstRow()) { count = rows.getLong(0); mailboxId = rows.getString(1); } } finally { rows.close(); }
    if (count < 0 || !mailboxId) { return; }
    const delta = UnreadBadgeStore.contribution(current, mailboxId) - UnreadBadgeStore.contribution(previous, mailboxId);
    if (delta !== 0) {
      await this.db.executeSql('UPDATE mail_unread_badges SET unread_count = MAX(0, unread_count + ?) WHERE account_id = ?', [delta, accountId]);
    }
  }
}
