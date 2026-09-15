// MPL-2.0: https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { rdbTextProjection, readRdbText, RDB_TEXT_INLINE_BYTES } from './RdbText';
import { CachedEmail, cacheIsFresh, decodeCachedEmail, failedEmptyMailBody } from './MailCacheModel';
import { decodePreparedDocument } from './PreparedDocumentModel';
import { failedEmptyPreparedDocument } from './FailedBodyRecovery';
import { encodeMailSyncEmail } from './MailSyncModel';
import { stableMessageKey } from '../mail/Conversation';

interface FailedBodyRecord { row: number; account: string; id: string; payload: string; bytes: number; }

// One additive, resumable upgrade repair. Never inspect completed bodies on
// enqueue/IDLE; ordinary sync preserves their immutable prepared documents.
export async function recoverFailedEmptyBodies(db: relationalStore.RdbStore): Promise<void> {
  await db.executeSql('CREATE TABLE IF NOT EXISTS mail_sync_repairs (version INTEGER PRIMARY KEY)');
  const repaired = await db.querySql('SELECT version FROM mail_sync_repairs WHERE version = 1');
  try { if (repaired.goToFirstRow()) { return; } } finally { repaired.close(); }
  const tables = await db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('mail_cache', 'prepared_documents')");
  let available = 0;
  try { while (tables.goToNextRow()) { available++; } } finally { tables.close(); }
  if (available !== 2) { return; }
  let after = 0;
  while (true) {
    // Saved JSON is canonical. Filter known decoder-error/null records inside
    // SQLite so good body strings never cross the native boundary for repair.
    const rows = await db.querySql(`SELECT c.rowid, c.account_id, c.cache_key, ${rdbTextProjection('c.payload')}, length(CAST(c.payload AS BLOB))
      FROM mail_cache c JOIN accounts a ON a.id = c.account_id
      WHERE a.status = 'ready' AND c.kind = 'email' AND c.rowid > ? AND length(c.payload) <= 8388608
      AND instr(c.payload, '"bodyEncodingProblem":true') > 0 AND instr(c.payload, '"textBody":null') > 0
      ORDER BY c.rowid LIMIT 8`, [after]);
    const records: FailedBodyRecord[] = [];
    try { while (rows.goToNextRow()) {
      records.push({ row: rows.getLong(0), account: rows.getString(1), id: rows.getString(2), payload: rows.getString(3), bytes: rows.getLong(4) });
    } } finally { rows.close(); }
    if (records.length === 0) { break; }
    for (const record of records) {
      after = record.row;
      if (record.bytes > RDB_TEXT_INLINE_BYTES) {
        const payload = await readRdbText(db, `SELECT c.payload AS payload FROM mail_cache c JOIN accounts a ON a.id = c.account_id
          WHERE a.status = 'ready' AND c.rowid = ? AND c.account_id = ? AND c.kind = 'email' AND c.cache_key = ?`,
          [record.row, record.account, record.id], 8 * 1024 * 1024, record.bytes);
        if (payload === null) { continue; }
        record.payload = payload;
      }
      let cached: CachedEmail;
      try { cached = decodeCachedEmail(record.payload); } catch (_) { continue; }
      // File-backed partial bodies intentionally omit inline text/HTML; that
      // metadata shape is not evidence of a failed empty decoder result.
      if (cached.bodyFiles || cached.mail.id !== record.id || !cacheIsFresh(cached.bodySavedAt) || !failedEmptyMailBody(cached.mail)) { continue; }
      const key = stableMessageKey(cached.mail);
      let blankPayload: string | null = null;
      const documents = await db.querySql(`SELECT payload FROM prepared_documents
        WHERE account_id = ? AND message_key = ? AND body_saved_at = ? AND state = 'ready' AND length(payload) <= 65536`,
        [record.account, key, cached.bodySavedAt]);
      try { if (documents.goToFirstRow()) {
        const payload = documents.getString(0);
        try {
          if (failedEmptyPreparedDocument(decodePreparedDocument(payload, key), cached.bodySavedAt)) { blankPayload = payload; }
        } catch (_) { /* Never remove an unclassified or valid shared snapshot. */ }
      } } finally { documents.close(); }
      db.beginTransaction();
      try {
        // A concurrent successful body save defeats all changes atomically.
        // The current failed raw payload is authoritative even if a competing
        // worker completed with an older body timestamp. Existing unfinished
        // attempts retain their backoff across restart.
        const guard = "EXISTS (SELECT 1 FROM mail_cache c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' AND c.cache_key = ? AND c.payload = ?)";
        await db.executeSql(`INSERT INTO mail_sync_jobs (account_id, email_id, payload, stage, attempts, retry_at, body_saved_at, message_key, queued_at)
          SELECT ?, ?, ?, 'body', 0, 0, 0, '', ? WHERE ${guard}
          ON CONFLICT(account_id, email_id) DO UPDATE SET stage = 'body', attempts = 0, retry_at = 0, body_saved_at = 0,
          message_key = '', payload = excluded.payload, queued_at = excluded.queued_at
          WHERE mail_sync_jobs.stage IN ('done', 'pictures')`,
          [record.account, record.id, encodeMailSyncEmail(cached.mail), Date.now(), record.account, record.id, record.payload]);
        if (blankPayload !== null) {
          await db.executeSql(`DELETE FROM prepared_documents WHERE account_id = ? AND message_key = ?
            AND body_saved_at = ? AND state = 'ready' AND payload = ? AND ${guard}`,
            [record.account, key, cached.bodySavedAt, blankPayload, record.account, record.id, record.payload]);
        }
        // Keep the header/preview and error evidence, but a failed decoder's
        // timestamp must not make the local-only reader report a saved body.
        cached.bodySavedAt = null;
        await db.executeSql(`UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email'
          AND cache_key = ? AND payload = ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
          [JSON.stringify(cached), record.account, record.id, record.payload, record.account]);
        db.commit();
      } catch (_) { db.rollBack(); throw new Error('Failed body recovery could not be saved'); }
    }
  }
  await db.executeSql('INSERT OR IGNORE INTO mail_sync_repairs (version) VALUES (1)');
}
