// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { JmapEmail, JmapEmailPage } from '../mail/jmap/JmapClient';
import { CachedMailList, MAIL_RETENTION_MS } from './MailCacheModel';
import { MailSyncJob, MailSyncCursor, MailSyncStage, MAX_MAIL_SYNC_PAYLOAD,
  mailSyncIdentity, encodeMailSyncEmail, decodeMailSyncEmail, validateMailSyncPage, mailSyncHead } from './MailSyncModel';
import { recoverFailedEmptyBodies } from './MailSyncRecovery';

type Queue = (operation: () => Promise<void>) => Promise<void>;
interface MailSyncPayload { id: string; payload: string; }

// Both the backlog and traversal checkpoint live in the encrypted account DB.
// Limits apply to one row/selection, never to the number of pending messages.
export class MailSyncStore {
  private db: relationalStore.RdbStore;
  private queue: Queue;
  constructor(db: relationalStore.RdbStore, queue: Queue) { this.db = db; this.queue = queue; }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql("CREATE TABLE IF NOT EXISTS mail_sync_jobs (account_id TEXT NOT NULL, email_id TEXT NOT NULL, payload TEXT NOT NULL, stage TEXT NOT NULL, attempts INTEGER NOT NULL, retry_at INTEGER NOT NULL, body_saved_at INTEGER NOT NULL, message_key TEXT NOT NULL, queued_at INTEGER NOT NULL, PRIMARY KEY (account_id, email_id))");
    await db.executeSql('CREATE INDEX IF NOT EXISTS mail_sync_jobs_due ON mail_sync_jobs (account_id, stage, retry_at, queued_at)');
    await db.executeSql('CREATE TABLE IF NOT EXISTS mail_sync_cursors (account_id TEXT NOT NULL, mailbox_id TEXT NOT NULL, head TEXT NOT NULL, revision INTEGER NOT NULL, position INTEGER NOT NULL, query_state TEXT NOT NULL, attempts INTEGER NOT NULL, retry_at INTEGER NOT NULL, started_at INTEGER NOT NULL, PRIMARY KEY (account_id, mailbox_id))');
    await db.executeSql('DELETE FROM mail_sync_jobs WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = mail_sync_jobs.account_id)');
    await db.executeSql('DELETE FROM mail_sync_cursors WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = mail_sync_cursors.account_id)');
    await recoverFailedEmptyBodies(db);
  }

  private identity(accountId: string, id: string): void {
    if (!mailSyncIdentity(accountId) || !mailSyncIdentity(id)) { throw new Error('Invalid mail sync identity'); }
  }

  private selectedAccounts(accountIds: string[]): string[] {
    if (accountIds.length > 500 || accountIds.some(id => !mailSyncIdentity(id))) { throw new Error('Invalid mail sync accounts'); }
    return Array.from(new Set<string>(accountIds));
  }

  private retryTime(retryAt: number): number {
    if (!Number.isSafeInteger(retryAt) || retryAt < 0) { throw new Error('Invalid mail sync retry'); }
    const now = Date.now();
    return Math.min(Math.max(retryAt, now + 1000), now + 24 * 60 * 60 * 1000);
  }

  private records(emails: JmapEmail[]): MailSyncPayload[] {
    return emails.map(email => ({ id: email.id, payload: encodeMailSyncEmail(email) } as MailSyncPayload));
  }

  private async put(accountId: string, emailId: string, payload: string, cursor?: MailSyncCursor): Promise<void> {
    const now = Date.now();
    const guard = cursor ? ' AND EXISTS (SELECT 1 FROM mail_sync_cursors WHERE account_id = ? AND mailbox_id = ? AND revision = ? AND position = ? AND head = ?)' : '';
    const args: relationalStore.ValueType[] = [emailId, payload, now, accountId];
    if (cursor) { args.push(cursor.accountId, cursor.mailboxId, cursor.revision, cursor.position === null ? -1 : cursor.position, cursor.head); }
    args.push(now - MAIL_RETENTION_MS, now);
    // A terminal marker cannot stand in for this protocol ID's missing raw
    // body. Cache writers put bodySavedAt before mail in their canonical JSON;
    // inspect only that bounded prefix inside SQLite, never transfer/parse a
    // completed body on every header registration. Unknown formats stay intact.
    // This also repairs .24 records whose one-time failed-body migration ran
    // before a stale completion timestamp was reconciled. Documents and picture
    // attempts retain their independent immutable state.
    await this.db.executeSql(`INSERT INTO mail_sync_jobs (account_id, email_id, payload, stage, attempts, retry_at, body_saved_at, message_key, queued_at)
      SELECT id, ?, ?, 'body', 0, 0, 0, '', ? FROM accounts WHERE id = ? AND status = 'ready'${guard}
      ON CONFLICT(account_id, email_id) DO UPDATE SET payload = excluded.payload,
      stage = 'body', attempts = 0, retry_at = 0, body_saved_at = 0, message_key = '', queued_at = excluded.queued_at
      WHERE mail_sync_jobs.stage = 'done' AND (mail_sync_jobs.body_saved_at <= ? OR mail_sync_jobs.body_saved_at > ?
        OR NOT EXISTS (SELECT 1 FROM mail_cache c WHERE c.account_id = mail_sync_jobs.account_id
          AND c.kind = 'email' AND c.cache_key = mail_sync_jobs.email_id
          AND NOT (substr(c.payload, 1, 13) = '{"version":1,'
            AND instr(substr(c.payload, 1, instr(substr(c.payload, 1, 192), ',"mail":')),
              '"bodySavedAt":null,') > 0)))`, args);
  }

  enqueue(accountId: string, emails: JmapEmail[]): Promise<void> {
    this.identity(accountId, 'queue');
    const records = this.records(emails);
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        for (const record of records) { await this.put(accountId, record.id, record.payload); }
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail sync could not be saved'); }
    });
  }

  async next(accountIds: string[], stage: MailSyncStage, limit: number = 1): Promise<MailSyncJob[]> {
    const accounts = this.selectedAccounts(accountIds);
    if (stage !== 'body' && stage !== 'pictures') { throw new Error('Invalid mail sync stage'); }
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) { throw new Error('Invalid mail sync selection'); }
    if (accounts.length === 0) { return []; }
    const result: MailSyncJob[] = [];
    await this.queue(async () => {
      const rows = await this.db.querySql(`SELECT j.account_id, j.email_id, length(j.payload), j.payload, j.attempts, j.retry_at, j.body_saved_at, j.message_key
        FROM mail_sync_jobs j JOIN accounts a ON a.id = j.account_id WHERE a.status = 'ready'
        AND j.account_id IN (${accounts.map(() => '?').join(',')}) AND j.stage = ? AND j.retry_at <= ?
        ORDER BY j.queued_at, j.account_id, j.email_id LIMIT ?`, [...accounts, stage, Date.now(), limit]);
      try {
        while (rows.goToNextRow()) {
          if (rows.getLong(2) > MAX_MAIL_SYNC_PAYLOAD) { throw new Error('Invalid mail sync metadata'); }
          result.push({ accountId: rows.getString(0), email: decodeMailSyncEmail(rows.getString(3), rows.getString(1)),
            stage, attempts: rows.getLong(4), retryAt: rows.getLong(5), bodySavedAt: rows.getLong(6), messageKey: rows.getString(7) });
        }
      } finally { rows.close(); }
    });
    return result;
  }

  // A quiet mailbox still needs one wake when a failed durable job becomes
  // eligible again. Empty/completed work produces no deadline and no polling.
  async nextRetryAt(accountIds: string[]): Promise<number | null> {
    const accounts = this.selectedAccounts(accountIds);
    if (accounts.length === 0) { return null; }
    let result: number | null = null;
    await this.queue(async () => {
      const selected = accounts.map(() => '?').join(',');
      const rows = await this.db.querySql(`WITH eligible_sync_accounts AS
        (SELECT id FROM accounts WHERE status = 'ready' AND id IN (${selected}))
        SELECT j.retry_at FROM mail_sync_jobs j
        JOIN eligible_sync_accounts a ON a.id = j.account_id
        WHERE j.stage IN ('body', 'pictures') AND j.retry_at > 0
        UNION ALL SELECT c.retry_at FROM mail_sync_cursors c
        JOIN eligible_sync_accounts a ON a.id = c.account_id
        WHERE c.position >= 0 AND c.retry_at > 0
        ORDER BY retry_at LIMIT 1`, accounts);
      try { if (rows.goToFirstRow()) { result = rows.getLong(0); } }
      finally { rows.close(); }
    });
    return result;
  }

  markPictures(accountId: string, emailId: string, bodySavedAt: number = Date.now(), messageKey: string = ''): Promise<void> {
    this.identity(accountId, emailId);
    if (messageKey !== '' && !mailSyncIdentity(messageKey)) { throw new Error('Invalid mail sync document identity'); }
    if (!Number.isSafeInteger(bodySavedAt) || bodySavedAt < 0 || bodySavedAt > Date.now()) { throw new Error('Invalid mail sync body timestamp'); }
    return this.queue(async () => {
      await this.db.executeSql("UPDATE mail_sync_jobs SET stage = 'pictures', attempts = 0, retry_at = 0, body_saved_at = ?, message_key = ? WHERE account_id = ? AND email_id = ? AND stage = 'body' AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [bodySavedAt, messageKey, accountId, emailId, accountId]);
    });
  }

  complete(accountId: string, emailId: string): Promise<void> {
    this.identity(accountId, emailId);
    return this.queue(async () => {
      await this.db.executeSql("UPDATE mail_sync_jobs SET stage = 'done', attempts = 0, retry_at = 0 WHERE account_id = ? AND email_id = ? AND stage = 'pictures' AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [accountId, emailId, accountId]);
    });
  }

  requeueBody(accountId: string, emailId: string): Promise<void> {
    this.identity(accountId, emailId);
    return this.queue(async () => {
      await this.db.executeSql("UPDATE mail_sync_jobs SET stage = 'body', attempts = 0, retry_at = 0, body_saved_at = 0, message_key = '' WHERE account_id = ? AND email_id = ? AND stage = 'pictures' AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [accountId, emailId, accountId]);
    });
  }

  discard(accountId: string, emailId: string): Promise<void> {
    this.identity(accountId, emailId);
    return this.queue(async () => { await this.db.executeSql('DELETE FROM mail_sync_jobs WHERE account_id = ? AND email_id = ?', [accountId, emailId]); });
  }

  defer(accountId: string, emailId: string, retryAt: number): Promise<void> {
    this.identity(accountId, emailId); const deadline = this.retryTime(retryAt);
    return this.queue(async () => {
      await this.db.executeSql("UPDATE mail_sync_jobs SET attempts = min(attempts + 1, 1000000), retry_at = ? WHERE account_id = ? AND email_id = ? AND stage != 'done' AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [deadline, accountId, emailId, accountId]);
    });
  }

  private async cursor(accountId: string, mailboxId: string): Promise<MailSyncCursor | null> {
    const rows = await this.db.querySql("SELECT c.account_id, c.mailbox_id, c.head, c.revision, c.position, c.query_state, c.attempts, c.retry_at FROM mail_sync_cursors c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.mailbox_id = ?", [accountId, mailboxId]);
    try { return rows.goToFirstRow() ? this.cursorRow(rows) : null; } finally { rows.close(); }
  }

  private cursorRow(rows: relationalStore.ResultSet): MailSyncCursor {
    const position = rows.getLong(4);
    return { accountId: rows.getString(0), mailboxId: rows.getString(1), head: rows.getString(2), revision: rows.getLong(3),
      position: position < 0 ? null : position, queryState: rows.getString(5), attempts: rows.getLong(6), retryAt: rows.getLong(7) };
  }

  private copyCursor(cursor: MailSyncCursor): MailSyncCursor {
    return { accountId: cursor.accountId, mailboxId: cursor.mailboxId, head: cursor.head,
      revision: cursor.revision, position: cursor.position, queryState: cursor.queryState,
      attempts: cursor.attempts, retryAt: cursor.retryAt };
  }

  async seedPage(accountId: string, mailboxId: string, page: JmapEmailPage): Promise<MailSyncCursor | null> {
    this.identity(accountId, mailboxId); const head = mailSyncHead(page);
    const records = this.records(page.emails), nextPosition = page.nextPosition, queryState = page.queryState;
    let result: MailSyncCursor | null = null;
    await this.queue(async () => {
      const now = Date.now(); this.db.beginTransaction();
      try {
        for (const record of records) { await this.put(accountId, record.id, record.payload); }
        await this.db.executeSql(`INSERT INTO mail_sync_cursors (account_id, mailbox_id, head, revision, position, query_state, attempts, retry_at, started_at)
          SELECT id, ?, ?, 1, ?, ?, 0, 0, ? FROM accounts WHERE id = ? AND status = 'ready'
          ON CONFLICT(account_id, mailbox_id) DO UPDATE SET head = excluded.head, revision = mail_sync_cursors.revision + 1,
          position = excluded.position, query_state = excluded.query_state, attempts = 0, retry_at = 0, started_at = excluded.started_at
          WHERE mail_sync_cursors.head != excluded.head OR mail_sync_cursors.started_at <= ? OR mail_sync_cursors.started_at > ?`,
          [mailboxId, head, nextPosition === null ? -1 : nextPosition, queryState, now, accountId, now - MAIL_RETENTION_MS, now]);
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail sync page could not be saved'); }
      // Native pooled reads see the committed winner, never transaction state.
      result = await this.cursor(accountId, mailboxId);
    });
    return result;
  }

  async seedCached(accountId: string, mailboxId: string, cached: CachedMailList): Promise<MailSyncCursor | null> {
    this.identity(accountId, mailboxId);
    const records = this.records(cached.emails);
    const queryState = typeof cached.queryState === 'string' && cached.queryState.length <= 65536 ? cached.queryState : '';
    const validPosition = cached.nextPosition === null || (Number.isSafeInteger(cached.nextPosition) && (cached.nextPosition as number) >= 0);
    const position = queryState !== '' && validPosition ? (cached.nextPosition === null ? -1 : cached.nextPosition as number) : 0;
    let result: MailSyncCursor | null = null;
    await this.queue(async () => {
      const now = Date.now(); this.db.beginTransaction();
      try {
        for (const record of records) { await this.put(accountId, record.id, record.payload); }
        // A merged cached view is not a first-page identity. It may create a
        // missing checkpoint, but must never rewind an existing live traversal.
        await this.db.executeSql(`INSERT INTO mail_sync_cursors (account_id, mailbox_id, head, revision, position, query_state, attempts, retry_at, started_at)
          SELECT id, ?, '', 1, ?, ?, 0, 0, ? FROM accounts WHERE id = ? AND status = 'ready'
          ON CONFLICT(account_id, mailbox_id) DO UPDATE SET head = '', revision = mail_sync_cursors.revision + 1,
          position = 0, query_state = '', attempts = 0, retry_at = 0, started_at = excluded.started_at
          WHERE mail_sync_cursors.started_at <= ? OR mail_sync_cursors.started_at > ?`,
          [mailboxId, position, position === 0 ? '' : queryState, now, accountId, now - MAIL_RETENTION_MS, now]);
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Cached mail sync could not be saved'); }
      result = await this.cursor(accountId, mailboxId);
    });
    return result;
  }

  async nextCursor(accountIds: string[]): Promise<MailSyncCursor | null> {
    const accounts = this.selectedAccounts(accountIds); if (accounts.length === 0) { return null; }
    let result: MailSyncCursor | null = null;
    await this.queue(async () => {
      const rows = await this.db.querySql(`SELECT c.account_id, c.mailbox_id, c.head, c.revision, c.position, c.query_state, c.attempts, c.retry_at
        FROM mail_sync_cursors c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready'
        AND c.account_id IN (${accounts.map(() => '?').join(',')}) AND c.position >= 0 AND c.retry_at <= ?
        ORDER BY c.started_at, c.account_id, c.mailbox_id LIMIT 1`, [...accounts, Date.now()]);
      try { if (rows.goToFirstRow()) { result = this.cursorRow(rows); } } finally { rows.close(); }
    });
    return result;
  }

  async advance(cursor: MailSyncCursor, page: JmapEmailPage): Promise<boolean> {
    this.identity(cursor.accountId, cursor.mailboxId); validateMailSyncPage(page);
    if (cursor.position === null || page.position !== cursor.position) { throw new Error('Invalid mail sync continuation'); }
    const expected = this.copyCursor(cursor);
    const records = this.records(page.emails), nextPosition = page.nextPosition, queryState = page.queryState;
    let result = false;
    await this.queue(async () => {
      this.db.beginTransaction();
      try {
        for (const record of records) { await this.put(expected.accountId, record.id, record.payload, expected); }
        await this.db.executeSql(`UPDATE mail_sync_cursors SET revision = revision + 1, position = ?, query_state = ?, attempts = 0, retry_at = 0
          WHERE account_id = ? AND mailbox_id = ? AND revision = ? AND position = ? AND head = ?
          AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
          [nextPosition === null ? -1 : nextPosition, queryState, expected.accountId, expected.mailboxId,
            expected.revision, expected.position, expected.head, expected.accountId]);
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail sync continuation could not be saved'); }
      const saved = await this.cursor(expected.accountId, expected.mailboxId);
      result = saved !== null && saved.head === expected.head && saved.revision === expected.revision + 1 && saved.position === nextPosition;
    });
    return result;
  }

  deferCursor(cursor: MailSyncCursor, retryAt: number): Promise<void> {
    this.identity(cursor.accountId, cursor.mailboxId); const deadline = this.retryTime(retryAt);
    const expected = this.copyCursor(cursor);
    return this.queue(async () => {
      await this.db.executeSql(`UPDATE mail_sync_cursors SET attempts = min(attempts + 1, 1000000), retry_at = ?
        WHERE account_id = ? AND mailbox_id = ? AND revision = ? AND position = ? AND head = ?
        AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
        [deadline, expected.accountId, expected.mailboxId, expected.revision, expected.position === null ? -1 : expected.position, expected.head, expected.accountId]);
    });
  }

  restartCursor(cursor: MailSyncCursor, retryAt: number): Promise<void> {
    this.identity(cursor.accountId, cursor.mailboxId); const deadline = this.retryTime(retryAt);
    const expected = this.copyCursor(cursor);
    return this.queue(async () => {
      await this.db.executeSql(`UPDATE mail_sync_cursors SET revision = revision + 1, position = 0, query_state = '', head = '',
        attempts = min(attempts + 1, 1000000), retry_at = ?, started_at = ?
        WHERE account_id = ? AND mailbox_id = ? AND revision = ? AND position = ? AND head = ?
        AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
        [deadline, Date.now(), expected.accountId, expected.mailboxId, expected.revision, expected.position === null ? -1 : expected.position, expected.head, expected.accountId]);
    });
  }
}
