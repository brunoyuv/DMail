// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { MAIL_RETENTION_MS, cacheIsFresh } from './MailCacheModel';
import { RDB_TEXT_INLINE_BYTES, rdbTextProjection, readRdbText } from './RdbText';
import { MailContentFileStore, mailContentReferenceValid } from './MailContentFileModel';
import { PreparedDocumentPicture, PreparedDocumentState, PreparedMailDocument,
  PreparedDocumentRecord, PREPARED_DOCUMENT_VERSION, MAX_PREPARED_HTML, MAX_PREPARED_PAYLOAD, preparedDocumentIdentity,
  encodePreparedDocument, validatePreparedDocument, encodePreparedRecord, decodePreparedRecord } from './PreparedDocumentModel';

type Queue = (operation: () => Promise<void>) => Promise<void>;

// Prepared markup is distinct from the original body. Pictures remain in the
// existing picture cache; only their local-document identities are stored here.
export class PreparedDocumentStore {
  private db: relationalStore.RdbStore;
  private queue: Queue;
  private files?: MailContentFileStore;
  constructor(db: relationalStore.RdbStore, queue: Queue, files?: MailContentFileStore) {
    this.db = db; this.queue = queue; this.files = files;
  }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS prepared_documents (account_id TEXT NOT NULL, message_key TEXT NOT NULL, body_saved_at INTEGER NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY (account_id, message_key))');
    const now = Date.now();
    // Retain the attempt/time after releasing expired markup. Only a newly
    // downloaded body may replace it; ordinary header sync cannot renew it.
    await db.executeSql("UPDATE prepared_documents SET state = 'expired', payload = '' WHERE body_saved_at <= ? OR body_saved_at > ?", [now - MAIL_RETENTION_MS, now]);
    await db.executeSql('DELETE FROM prepared_documents WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = prepared_documents.account_id)');
  }

  async read(accountId: string, messageKey: string): Promise<PreparedDocumentState> {
    if (!preparedDocumentIdentity(accountId, messageKey)) { throw new Error('Invalid prepared document identity'); }
    let result: PreparedDocumentState = { attempted: false, document: null, bodySavedAt: null, failure: '' };
    try { await this.queue(async () => { result = await this.get(accountId, messageKey); }); }
    catch (_) { throw new Error('Prepared document storage is unavailable'); }
    return result;
  }

  private async get(accountId: string, messageKey: string, migrate: boolean = true): Promise<PreparedDocumentState> {
    // The RDB ResultSet cannot expose a row above 2 MiB even when SQLite saved
    // it successfully. Read metadata and small documents inline; large UTF-8
    // payloads use bounded native rows without changing their persisted format.
    const rows = await this.db.querySql(`SELECT p.body_saved_at, p.state, length(p.payload),
      length(CAST(p.payload AS BLOB)), ${rdbTextProjection('p.payload')}
      FROM prepared_documents p JOIN accounts a ON a.id = p.account_id
      WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ?`, [accountId, messageKey]);
    let bodySavedAt = 0, state = '', characters = 0, bytes = 0, payload = '';
    try {
      if (!rows.goToFirstRow()) { return { attempted: false, document: null, bodySavedAt: null, failure: '' }; }
      bodySavedAt = rows.getLong(0); state = rows.getString(1);
      characters = rows.getLong(2); bytes = rows.getLong(3); payload = rows.getString(4);
    } finally { rows.close(); }
    if (!Number.isSafeInteger(bodySavedAt) || bodySavedAt < 0 || !['ready', 'failed', 'expired'].includes(state)) {
      throw new Error('Prepared document storage is invalid');
    }
    if (!cacheIsFresh(bodySavedAt) || state === 'expired') {
      return { attempted: true, document: null, bodySavedAt, failure: 'expired' };
    }
    if (state === 'failed') { return { attempted: true, document: null, bodySavedAt, failure: 'failed' }; }
    if (characters > MAX_PREPARED_PAYLOAD) { throw new Error('Prepared document storage is invalid'); }
    if (bytes > RDB_TEXT_INLINE_BYTES) {
      const large = await readRdbText(this.db, `SELECT p.payload AS payload FROM prepared_documents p
        JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ?
        AND p.body_saved_at = ? AND p.state = 'ready'`, [accountId, messageKey, bodySavedAt], MAX_PREPARED_PAYLOAD, bytes);
      if (large === null) { throw new Error('Prepared document storage changed'); }
      payload = large;
    }
    const record = decodePreparedRecord(payload, messageKey);
    if (record.bodySavedAt !== bodySavedAt) { throw new Error('Prepared document storage is invalid'); }
    let html = record.html || '';
    if (record.htmlFile !== undefined) {
      if (!this.files || !mailContentReferenceValid(accountId, record.htmlFile, 'html')) {
        throw new Error('Prepared document file is unavailable');
      }
      html = await this.files.read(accountId, record.htmlFile, MAX_PREPARED_HTML);
    }
    const document: PreparedMailDocument = { version: record.version, messageKey: record.messageKey,
      bodySavedAt: record.bodySavedAt, savedAt: record.savedAt, html, pictures: record.pictures };
    validatePreparedDocument(document, messageKey);
    if (this.files && record.htmlFile === undefined && migrate) {
      // File first, then an exact guarded reference replacement. A lost race
      // leaves an unreferenced file for retention cleanup, never a broken row.
      try {
        const replacement = await this.filePayload(accountId, document);
        await this.db.executeSql(`UPDATE prepared_documents SET payload = ? WHERE account_id = ? AND message_key = ?
          AND body_saved_at = ? AND state = 'ready' AND payload = ?
          AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
          [replacement, accountId, messageKey, bodySavedAt, payload, accountId]);
      } catch (_) {
        // Migration is optional. The fully decoded old snapshot still owns
        // its picture identities only while its account and exact row remain
        // current after the failed asynchronous file/reference write.
        await this.requireCurrent(accountId, messageKey, bodySavedAt, payload);
        return { attempted: true, document, bodySavedAt, failure: '' };
      }
      return this.get(accountId, messageKey, false);
    }
    if (record.htmlFile !== undefined) {
      // File I/O yields to other database handles. Revalidate the small stored
      // metadata/reference before returning hydrated HTML from the old file.
      await this.requireCurrent(accountId, messageKey, bodySavedAt, payload);
    }
    return { attempted: true, document, bodySavedAt, failure: '' };
  }

  private async requireCurrent(accountId: string, messageKey: string, bodySavedAt: number, payload: string): Promise<void> {
    const rows = await this.db.querySql(`SELECT 1 FROM prepared_documents p JOIN accounts a ON a.id = p.account_id
      WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ? AND p.body_saved_at = ?
      AND p.state = 'ready' AND p.payload = ?`, [accountId, messageKey, bodySavedAt, payload]);
    try {
      if (!rows.goToFirstRow()) { throw new Error('Prepared document storage changed'); }
    } finally { rows.close(); }
  }

  private async filePayload(accountId: string, document: PreparedMailDocument): Promise<string> {
    if (!this.files) { return encodePreparedDocument(document); }
    const reference = await this.files.write(accountId, 'html', document.html);
    if (!mailContentReferenceValid(accountId, reference, 'html')) { throw new Error('Invalid prepared document file'); }
    const record: PreparedDocumentRecord = { version: document.version, messageKey: document.messageKey,
      bodySavedAt: document.bodySavedAt, savedAt: document.savedAt, pictures: document.pictures, htmlFile: reference };
    return encodePreparedRecord(record);
  }

  save(accountId: string, messageKey: string, html: string, pictures: PreparedDocumentPicture[], bodySavedAt: number): Promise<PreparedDocumentState> {
    const document: PreparedMailDocument = { version: PREPARED_DOCUMENT_VERSION, messageKey,
      bodySavedAt, savedAt: Date.now(), html,
      pictures: pictures.map((picture: PreparedDocumentPicture): PreparedDocumentPicture => ({ id: picture.id, url: picture.url })) };
    validatePreparedDocument(document, messageKey);
    return this.put(accountId, messageKey, bodySavedAt, 'ready', document);
  }

  fail(accountId: string, messageKey: string, bodySavedAt: number): Promise<PreparedDocumentState> {
    return this.put(accountId, messageKey, bodySavedAt, 'failed', null);
  }

  private async put(accountId: string, messageKey: string, bodySavedAt: number, state: string,
    document: PreparedMailDocument | null): Promise<PreparedDocumentState> {
    if (!preparedDocumentIdentity(accountId, messageKey) || !Number.isSafeInteger(bodySavedAt) || !cacheIsFresh(bodySavedAt)) {
      throw new Error('Invalid prepared document identity');
    }
    let result: PreparedDocumentState = { attempted: false, document: null, bodySavedAt: null, failure: '' };
    try { await this.queue(async () => {
      // Avoid rewriting a completed file on another open or attempted save.
      // Missing completed files remain errors, never implicit rescan permission.
      const previous = await this.get(accountId, messageKey);
      if (previous.attempted && cacheIsFresh(previous.bodySavedAt)) { result = previous; return; }
      const owner = await this.db.querySql("SELECT 1 FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
      try { if (!owner.goToFirstRow()) { return; } } finally { owner.close(); }
      const payload = document ? await this.filePayload(accountId, document) : '';
      const now = Date.now();
      // An atomic upsert also freezes competing stores on other RDB handles.
      // The timestamp condition prevents stale sync results replacing a newer
      // valid document. A future timestamp is invalid after clock rollback and
      // may be repaired by a currently fresh body; it must not block sync forever.
      await this.db.executeSql(`INSERT INTO prepared_documents (account_id, message_key, body_saved_at, state, payload)
        SELECT id, ?, ?, ?, ? FROM accounts WHERE id = ? AND status = 'ready'
        ON CONFLICT(account_id, message_key) DO UPDATE SET body_saved_at = excluded.body_saved_at,
        state = excluded.state, payload = excluded.payload
        WHERE (prepared_documents.body_saved_at <= ? AND excluded.body_saved_at > prepared_documents.body_saved_at)
        OR prepared_documents.body_saved_at > ?`,
        [messageKey, bodySavedAt, state, payload, accountId, now - MAIL_RETENTION_MS, now]);
      // executeSql has committed before the pooled reader verifies the winner.
      result = await this.get(accountId, messageKey);
    }); } catch (_) { throw new Error('Prepared document storage is unavailable'); }
    return result;
  }
}
