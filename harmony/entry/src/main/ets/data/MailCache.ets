// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { UnreadBadgeStore } from './UnreadBadgeStore';
import { JmapEmail, JmapMailbox, JmapKeyword, shallowCopyEmail } from '../mail/jmap/JmapClient';
import { CachedEmail, CachedBodyFiles, CachedView, CachedBoxes, CachedMailList, cacheEmail, withCachedBodyFiles, hydratedCachedEmail, missingCachedEmail,
  decodeCachedEmail, decodeCachedView, decodeCachedBoxes, cacheIsFresh, retainedEmail, cachedEmailSummary, cacheReadyForReading, prunedEmailPayload, MAILBOX_ROLE_REVISION, attachmentCacheSources } from './MailCacheModel';
import { prependSentMessage, serverSentMailbox, sentMailbox, LOCAL_SENT_MAILBOX } from '../mail/smtp/SentMail';
import { MailContentFileStore, mailContentReferenceValid } from './MailContentFileModel';
import { RDB_TEXT_INLINE_BYTES, rdbTextProjection, readRdbText } from './RdbText';

type Queue = (operation: () => Promise<void>) => Promise<void>;
type LocalBodyLookup = () => Promise<Map<string, string[]>>;
interface StoredCache { account: string; kind: string; key: string; payload: string; bytes: number; dirty: number; rowid?: number; }
interface StoredPayload { payload: string; stateDirty: boolean; }

// Shares the encrypted account database and its serialized operation queue.
// The account join hides pending/deleting rows during crash recovery.
export class MailCache {
  private static mutationClock: number = 0;
  private static mutationVersions: Map<string, number> = new Map();
  private static liveMutations: Set<string> = new Set();
  private static movedIdentities: Set<string> = new Set();
  private static mailboxMutations: Map<string, number> = new Map();
  static mutationRevision(): number { return MailCache.mutationClock; }
  endMutation(accountId: string, emailId: string): void {
    const key = `${accountId}:${emailId}`;
    if (MailCache.liveMutations.delete(key)) { MailCache.mutationVersions.set(key, ++MailCache.mutationClock); }
  }

  private db: relationalStore.RdbStore;
  private queue: Queue;
  private badges?: UnreadBadgeStore;
  private files?: MailContentFileStore;
  private sqlSummaryProjection?: boolean;
  constructor(db: relationalStore.RdbStore, queue: Queue, badges?: UnreadBadgeStore, files?: MailContentFileStore) {
    this.db = db; this.queue = queue; this.badges = badges; this.files = files;
  }

  static async initialize(db: relationalStore.RdbStore, _files?: MailContentFileStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS mail_cache (account_id TEXT NOT NULL, kind TEXT NOT NULL, cache_key TEXT NOT NULL, payload TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (account_id, kind, cache_key))');
    await db.executeSql("CREATE INDEX IF NOT EXISTS mail_cache_dirty_email ON mail_cache (account_id, kind, dirty) WHERE kind = 'email' AND dirty != 0");
    // Do not retain a second in-memory copy of every downloaded body at launch.
    // Rowid pagination remains stable when this pass deletes expired rows.
    let after = 0;
    while (true) {
      const rows = await db.querySql(`SELECT rowid, account_id, kind, cache_key, ${rdbTextProjection('payload')},
        length(CAST(payload AS BLOB)), dirty FROM mail_cache WHERE rowid > ? ORDER BY rowid LIMIT 8`, [after]);
      const records: StoredCache[] = [];
      try { while (rows.goToNextRow()) {
        after = rows.getLong(0);
        records.push({ rowid: after, account: rows.getString(1), kind: rows.getString(2), key: rows.getString(3),
          payload: rows.getString(4), bytes: rows.getLong(5), dirty: rows.getLong(6) });
      } } finally { rows.close(); }
      if (records.length === 0) { break; }
      for (const record of records) {
        // New records contain only small file references. Legacy inline bodies
        // still need bounded reads; no referenced body file is opened at launch.
        if (record.bytes > RDB_TEXT_INLINE_BYTES) {
          try {
            const previous = await readRdbText(db, 'SELECT payload FROM mail_cache WHERE rowid = ? AND account_id = ? AND kind = ? AND cache_key = ? AND dirty = ?',
              [record.rowid!, record.account, record.kind, record.key, record.dirty], 8 * 1024 * 1024, record.bytes);
            if (previous === null) { continue; }
            record.payload = previous;
          } catch (_) { continue; }
        }
        let fresh = false; let payload = record.payload;
        try {
          if (record.kind === 'email') {
            const normalized = prunedEmailPayload(payload);
            fresh = normalized !== null;
            if (normalized !== null) { payload = normalized; }
          } else { fresh = cacheIsFresh(record.kind === 'view' ? decodeCachedView(payload).savedAt : decodeCachedBoxes(payload).savedAt); }
        } catch (_) {}
        const keys: relationalStore.ValueType[] = [record.account, record.kind, record.key, record.payload, record.dirty];
        if (!fresh) { await db.executeSql('DELETE FROM mail_cache WHERE account_id = ? AND kind = ? AND cache_key = ? AND payload = ? AND dirty = ?', keys); }
        else if (payload !== record.payload) { await db.executeSql('UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = ? AND cache_key = ? AND payload = ? AND dirty = ?', [payload, ...keys]); }
      }
    }
  }

  private async summaryProjection(): Promise<boolean> {
    if (this.sqlSummaryProjection !== undefined) { return this.sqlSummaryProjection; }
    try {
      const rows = await this.db.querySql(`SELECT json_set(json_remove('{"unused":1}', '$.unused'), '$.ok', json('true'))`);
      try { this.sqlSummaryProjection = rows.goToFirstRow() && rows.getString(0) === '{"ok":true}'; }
      finally { rows.close(); }
    } catch (_) { this.sqlSummaryProjection = false; }
    return this.sqlSummaryProjection;
  }

  async hasSqlSummaryProjection(): Promise<boolean> {
    let available = false;
    await this.queue(async () => { available = await this.summaryProjection(); });
    return available;
  }

  private async emailPayload(includeBody: boolean): Promise<string> {
    if (includeBody || !await this.summaryProjection()) { return 'c.payload'; }
    // SQLite projects before crossing the native/ArkTS boundary. Keep unknown
    // or corrupt JSON for the normal decoder to reject instead of aborting all
    // rows. Older SQLite builds use the bounded per-row JS fallback below.
    return `CASE WHEN json_valid(c.payload) THEN json_set(json_remove(c.payload, '$.mail.attachments'),
      '$.mail.cachedBodyAvailable', json(CASE WHEN json_type(c.payload, '$.mail.textBody') = 'text' OR json_type(c.payload, '$.mail.htmlBody') = 'text' OR
        json_type(c.payload, '$.bodyFiles.text') = 'text' OR json_type(c.payload, '$.bodyFiles.html') = 'text' THEN 'true' ELSE 'false' END),
      '$.mail.textBody', NULL, '$.mail.htmlBody', NULL, '$.summaryOnly', json('true')) ELSE c.payload END`;
  }

  private async get(accountId: string, kind: string, key: string, includeDirty: boolean = false, includeBody: boolean = true): Promise<StoredPayload | null> {
    const payload = kind === 'email' ? await this.emailPayload(includeBody) : 'c.payload';
    const rows = await this.db.querySql(`SELECT ${rdbTextProjection(payload)}, c.dirty, length(CAST((${payload}) AS BLOB)) FROM mail_cache c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = ? AND c.cache_key = ? AND (? = 1 OR c.dirty = 0)`,
      [accountId, kind, key, includeDirty ? 1 : 0]);
    let record: StoredCache | null = null;
    try { if (rows.goToFirstRow()) { record = { account: accountId, kind, key, payload: rows.getString(0), dirty: rows.getLong(1), bytes: rows.getLong(2) }; } }
    finally { rows.close(); }
    if (!record) { return null; }
    return { payload: await this.recordPayload(record, payload), stateDirty: record.dirty !== 0 };
  }

  private async recordPayload(record: StoredCache, expression: string = 'c.payload'): Promise<string> {
    if (record.bytes <= RDB_TEXT_INLINE_BYTES) { return record.payload; }
    const payload = await readRdbText(this.db, `SELECT ${expression} AS payload FROM mail_cache c
      JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = ? AND c.cache_key = ? AND c.dirty = ?`,
      [record.account, record.kind, record.key, record.dirty], 8 * 1024 * 1024, record.bytes);
    if (payload === null) { throw new Error('Mail cache changed'); }
    return payload;
  }

  private validBodyOwner(accountId: string, cached: CachedEmail): boolean {
    return (!cached.bodyFiles?.text || mailContentReferenceValid(accountId, cached.bodyFiles.text, 'text')) &&
      (!cached.bodyFiles?.html || mailContentReferenceValid(accountId, cached.bodyFiles.html, 'html'));
  }

  private async externalize(accountId: string, cached: CachedEmail): Promise<CachedEmail> {
    if (!this.validBodyOwner(accountId, cached)) { throw new Error('Invalid body file identity'); }
    if (!this.files || cached.bodyFiles || cached.bodySavedAt === null) { return cached; }
    const account = await this.db.querySql("SELECT 1 FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
    let ready = false;
    try { ready = account.goToFirstRow(); } finally { account.close(); }
    if (!ready) { return cached; }
    const references: CachedBodyFiles = {};
    if (cached.mail.textBody !== null) { references.text = await this.files.write(accountId, 'text', cached.mail.textBody); }
    if (typeof cached.mail.htmlBody === 'string') { references.html = await this.files.write(accountId, 'html', cached.mail.htmlBody); }
    if (!references.text && !references.html) { return cached; }
    const result = withCachedBodyFiles(cached, references);
    if (!this.validBodyOwner(accountId, result)) { throw new Error('Invalid body file identity'); }
    return result;
  }

  private async hydrate(accountId: string, cached: CachedEmail): Promise<CachedEmail | null> {
    if (!cached.bodyFiles) { return cached; }
    if (!this.files || !this.validBodyOwner(accountId, cached)) { return null; }
    try {
      let textBody = cached.mail.textBody, htmlBody = cached.mail.htmlBody;
      if (cached.bodyFiles.text) { textBody = await this.files.read(accountId, cached.bodyFiles.text, 8 * 1024 * 1024); }
      if (cached.bodyFiles.html) { htmlBody = await this.files.read(accountId, cached.bodyFiles.html, 8 * 1024 * 1024); }
      return hydratedCachedEmail(cached, textBody, htmlBody);
    } catch (_) { return null; }
  }

  private async migrateBody(accountId: string, cached: CachedEmail, stored: StoredPayload): Promise<string | null> {
    if (!this.files || cached.bodyFiles || cached.bodySavedAt === null) { return null; }
    try {
      const migrated = await this.externalize(accountId, cached);
      if (!migrated.bodyFiles) { return null; }
      // Immutable files are fully committed first. A concurrent metadata/body
      // writer wins this CAS; orphan files are left to normal retention.
      const payload = JSON.stringify(migrated);
      await this.db.executeSql(`UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email' AND cache_key = ?
        AND payload = ? AND dirty = ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')`,
        [payload, accountId, cached.mail.id, stored.payload, stored.stateDirty ? 1 : 0, accountId]);
      return payload;
    } catch (_) { /* A failed migration must not discard a still-readable inline body. */ }
    return null;
  }

  private async put(accountId: string, kind: string, key: string, payload: string): Promise<void> {
    // Legacy stores without the file service still obey the inline row limit.
    if (payload.length > 8 * 1024 * 1024) { throw new Error('Mail metadata exceeds its limit'); }
    await this.db.executeSql("INSERT OR REPLACE INTO mail_cache (account_id, kind, cache_key, payload, dirty) SELECT ?, ?, ?, ?, 0 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
      [accountId, kind, key, payload, accountId]);
  }

  saveBoxes(accountId: string, boxes: JmapMailbox[], readOnly?: boolean, revision: number = MailCache.mutationRevision()): Promise<void> {
    const value = decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: Date.now(), boxes, readOnly, roleRevision: MAILBOX_ROLE_REVISION } as CachedBoxes));
    return this.queue(async () => {
      // A LIST started before a verified CREATE/MOVE cannot erase its newly
      // committed folder. A later explicit list remains authoritative.
      if (revision < (MailCache.mailboxMutations.get(accountId) || 0)) { return; }
      this.db.beginTransaction();
      try {
        const reconciled = await this.reconcileSent(accountId, value);
        await this.put(accountId, 'boxes', '', JSON.stringify(reconciled));
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mailboxes could not be saved'); }
    });
  }

  async boxes(accountId: string): Promise<CachedBoxes | null> {
    let result: CachedBoxes | null = null;
    await this.queue(async () => {
      const payload = await this.get(accountId, 'boxes', '');
      const cached = payload === null ? null : decodeCachedBoxes(payload.payload);
      if (cached && cacheIsFresh(cached.savedAt)) {
        this.db.beginTransaction();
        try {
          result = await this.reconcileSent(accountId, cached);
          if (JSON.stringify(result) !== payload!.payload) { await this.put(accountId, 'boxes', '', JSON.stringify(result)); }
          this.db.commit();
        } catch (_) { this.db.rollBack(); throw new Error('Mailboxes could not be read'); }
      }
    });
    return result;
  }

  // Upgrade the former local Sent view in the same transaction as folder
  // metadata. This moves cached membership only, never retransmits a message.
  private async reconcileSent(accountId: string, value: CachedBoxes): Promise<CachedBoxes> {
    const localPayload = await this.get(accountId, 'view', LOCAL_SENT_MAILBOX, true);
    const previousLocal = localPayload ? decodeCachedView(localPayload.payload) : null;
    const localView = previousLocal && cacheIsFresh(previousLocal.savedAt) ? previousLocal : null;
    const target = serverSentMailbox(value.boxes);
    if (!target) {
      const boxes = value.boxes.filter(box => box.id !== LOCAL_SENT_MAILBOX);
      if (localView && localView.ids.length > 0) {
        const fallback = sentMailbox([], { accepted: true, messageId: '', date: 0, textBody: null, htmlBody: null, sentCopy: 'failed' });
        boxes.push(fallback);
      }
      value.boxes = boxes; return value;
    }
    const boxes = value.boxes.filter(box => box.id !== LOCAL_SENT_MAILBOX);
    if (!localView && !value.boxes.some(box => box.id === LOCAL_SENT_MAILBOX)) { value.boxes = boxes; return value; }
    const rows = await this.db.querySql(`SELECT cache_key, ${rdbTextProjection('payload')}, length(CAST(payload AS BLOB)), dirty FROM mail_cache WHERE account_id = ? AND kind = 'email'`, [accountId]);
    const moved: CachedEmail[] = [];
    const stored: StoredCache[] = [];
    try {
      while (rows.goToNextRow()) {
        stored.push({ account: accountId, kind: 'email', key: rows.getString(0), payload: rows.getString(1), bytes: rows.getLong(2), dirty: rows.getLong(3) });
      }
    } finally { rows.close(); }
    for (const record of stored) {
      const cached = decodeCachedEmail(await this.recordPayload(record));
      if (!cacheIsFresh(cached.savedAt) || !cached.mail.mailboxIds.includes(LOCAL_SENT_MAILBOX)) { continue; }
      cached.mail.mailboxIds = Array.from(new Set(cached.mail.mailboxIds.map(id => id === LOCAL_SENT_MAILBOX ? target.id : id)));
      moved.push(cached);
    }
    for (const cached of moved) {
      // UPDATE preserves dirty flags and every existing retention timestamp.
      await this.db.executeSql("UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [JSON.stringify(cached), accountId, cached.mail.id]);
    }
    const serverPayload = await this.get(accountId, 'view', target.id, true);
    const previousServer = serverPayload ? decodeCachedView(serverPayload.payload) : null;
    const serverView = previousServer && cacheIsFresh(previousServer.savedAt) ? previousServer : null;
    let messages: JmapEmail[] = [];
    for (const id of serverView?.ids || []) {
      const payload = await this.get(accountId, 'email', id, true);
      if (!payload) { continue; }
      let server = decodeCachedEmail(payload.payload);
      if (!cacheIsFresh(server.savedAt) || !server.mail.mailboxIds.includes(target.id)) { continue; }
      if (!cacheReadyForReading(server)) {
        const body = moved.find(copy => cacheReadyForReading(copy) && copy.mail.messageIds.some(messageId =>
          server.mail.messageIds.some(value => value.replace(/^<|>$/g, '') === messageId.replace(/^<|>$/g, ''))));
        if (body) {
          const previous = decodeCachedEmail(JSON.stringify(body));
          previous.mail.cachedAttachmentSourceIds = attachmentCacheSources(previous.mail);
          previous.mail.cachedSourceId = previous.mail.cachedSourceId || previous.mail.id;
          previous.mail.id = server.mail.id;
          const updated = cacheEmail(server.mail, false, previous, Date.now()); updated.savedAt = server.savedAt;
          server = updated;
          await this.db.executeSql("UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [JSON.stringify(server), accountId, id]);
        }
      }
      messages.push(server.mail);
    }
    for (const cached of moved) { messages = prependSentMessage(cached.mail, messages); }
    messages.sort((left, right) => right.receivedAt - left.receivedAt || left.id.localeCompare(right.id));
    if (messages.length > 0 || serverView) {
      const view: CachedView = { version: 1, mailboxId: target.id,
        savedAt: serverView?.savedAt ?? localView?.savedAt ?? Math.max(...moved.map(cached => cached.savedAt)),
        ids: messages.map(mail => mail.id), nextPosition: serverView?.nextPosition ?? null, queryState: serverView?.queryState };
      await this.put(accountId, 'view', target.id, JSON.stringify(view));
      if (serverPayload?.stateDirty || localPayload?.stateDirty) {
        await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'view' AND cache_key = ?", [accountId, target.id]);
      }
    }
    await this.db.executeSql("DELETE FROM mail_cache WHERE account_id = ? AND kind = 'view' AND cache_key = ?", [accountId, LOCAL_SENT_MAILBOX]);
    value.boxes = boxes; return value;
  }

  private async localSentBodyIndex(accountId: string): Promise<Map<string, string[]>> {
    const index = new Map<string, string[]>();
    const payload = await this.emailPayload(false);
    const rows = await this.db.querySql(`SELECT c.cache_key, ${rdbTextProjection(payload)}, length(CAST((${payload}) AS BLOB)), c.dirty FROM mail_cache c JOIN accounts a ON a.id = c.account_id
      WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' AND c.cache_key LIKE 'local_sent_%' ORDER BY c.cache_key`, [accountId]);
    const stored: StoredCache[] = [];
    try { while (rows.goToNextRow()) {
      stored.push({ account: accountId, kind: 'email', key: rows.getString(0), payload: rows.getString(1), bytes: rows.getLong(2), dirty: rows.getLong(3) });
    } } finally { rows.close(); }
    for (const record of stored) {
        try {
          const id = record.key, candidate = cachedEmailSummary(decodeCachedEmail(await this.recordPayload(record, payload)));
          if (candidate.mail.id !== id || !candidate.mail.cachedBodyAvailable) { continue; }
          for (const messageId of candidate.mail.messageIds) {
            const key = messageId.replace(/^<|>$/g, '');
            const copies = index.get(key) || [];
            if (!copies.includes(id)) { copies.push(id); }
            index.set(key, copies);
          }
        } catch (_) { /* A corrupt local copy must not prevent header caching. */ }
    }
    return index;
  }

  private async writeEmail(accountId: string, mail: JmapEmail, fullBody: boolean, revision: number = MailCache.mutationRevision(), localBodies?: LocalBodyLookup): Promise<void> {
    const identity = `${accountId}:${mail.id}`;
    if (MailCache.movedIdentities.has(identity) && (MailCache.mutationVersions.get(identity) || 0) > revision) { return; }
    const payload = await this.get(accountId, 'email', mail.id, true);
    let previous = payload === null ? null : decodeCachedEmail(payload.payload);
    const previousState = previous;
    // SMTP and the server's Sent UID are different local identities for the
    // same MIME Message-ID. Reuse the confirmed local body when headers arrive.
    if (!fullBody && !cacheReadyForReading(previous) && mail.messageIds.length > 0) {
      const index = localBodies ? await localBodies() : await this.localSentBodyIndex(accountId);
      const matching = new Set<string>();
      for (const messageId of mail.messageIds) {
        for (const id of index.get(messageId.replace(/^<|>$/g, '')) || []) { matching.add(id); }
      }
      for (const id of Array.from(matching).sort()) {
        const stored = await this.get(accountId, 'email', id, true);
        if (!stored) { continue; }
        const candidate = retainedEmail(decodeCachedEmail(stored.payload));
        if (cacheReadyForReading(candidate)) {
          candidate.mail.cachedAttachmentSourceIds = attachmentCacheSources(candidate.mail);
          candidate.mail.cachedSourceId = candidate.mail.cachedSourceId || candidate.mail.id;
          candidate.mail.id = mail.id; previous = candidate; break;
        }
      }
    }
    let value = cacheEmail(mail, fullBody, previous, Date.now());
    const key = `${accountId}:${mail.id}`;
    const preserveState = previousState !== null && (MailCache.liveMutations.has(key) || (MailCache.mutationVersions.get(key) || 0) > revision);
    if (preserveState && previousState) { value.mail.keywords = previousState.mail.keywords; value.mail.mailboxIds = previousState.mail.mailboxIds; }
    if (!this.validBodyOwner(accountId, value)) { throw new Error('Invalid body file identity'); }
    if (fullBody) { value = await this.externalize(accountId, value); }
    await this.put(accountId, 'email', mail.id, JSON.stringify(value));
    if (preserveState && payload?.stateDirty) {
      await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, mail.id]);
    }
  }

  saveEmail(accountId: string, mail: JmapEmail, revision: number = MailCache.mutationRevision()): Promise<void> {
    const copy = cacheEmail(mail, true, null, Date.now()).mail;
    return this.queue(() => this.writeEmail(accountId, copy, true, revision));
  }

  // Automatic mailbox traversal saves its headers without replacing the user's
  // visible page or its navigation cursor. Body/flag preservation is identical
  // to a normal header refresh, including mutations started during the request.
  saveSyncedEmails(accountId: string, emails: JmapEmail[], revision: number = MailCache.mutationRevision()): Promise<void> {
    const now = Date.now();
    const copies = emails.map(mail => cacheEmail(mail, false, null, now).mail);
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        let localIndex: Promise<Map<string, string[]>> | undefined;
        const localBodies: LocalBodyLookup = () => {
          const requested = localIndex || this.localSentBodyIndex(accountId);
          localIndex = requested; return requested;
        };
        for (const mail of copies) { await this.writeEmail(accountId, mail, false, revision, localBodies); }
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail cache could not be saved'); }
    });
  }

  // Append a confirmed outgoing body without rewriting the existing messages:
  // another background flag acknowledgement must keep its own data/dirty bit.
  appendSent(accountId: string, mail: JmapEmail, fallbackBox: JmapMailbox): Promise<void> {
    const copy = cacheEmail(mail, true, null, Date.now()).mail;
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const now = Date.now();
        const boxPayload = await this.get(accountId, 'boxes', '');
        const cachedBoxes = boxPayload ? decodeCachedBoxes(boxPayload.payload) : null;
        const boxes = cachedBoxes && cacheIsFresh(cachedBoxes.savedAt) ? cachedBoxes.boxes : [];
        const box: JmapMailbox = boxes.find(value => value.id === fallbackBox.id) || fallbackBox;
        // The SMTP result names the destination verified by the server LIST.
        if (fallbackBox.role === 'sent' && !fallbackBox.id.startsWith('local_')) { box.role = 'sent'; }
        const viewPayload = await this.get(accountId, 'view', box.id, true);
        const savedView = viewPayload ? decodeCachedView(viewPayload.payload) : null;
        const view = savedView && cacheIsFresh(savedView.savedAt) ? savedView : null;
        const existing: JmapEmail[] = [];
        for (const id of view?.ids || []) {
          const stored = await this.get(accountId, 'email', id, true);
          if (stored) { existing.push(retainedEmail(decodeCachedEmail(stored.payload)).mail); }
        }
        const messages = prependSentMessage(copy, existing);
        const newMessage = messages.length > existing.length;
        await this.writeEmail(accountId, copy, true);
        if (box.countsKnown !== false && newMessage) { box.totalEmails++; }
        const nextBoxes: CachedBoxes = { version: 1, savedAt: now,
          boxes: [...boxes.filter(value => value.id !== box.id), box], readOnly: cachedBoxes?.readOnly,
          roleRevision: cachedBoxes?.roleRevision };
        const nextView: CachedView = { version: 1, savedAt: now, mailboxId: box.id, ids: messages.map(value => value.id),
          nextPosition: view?.nextPosition ?? null, queryState: view?.queryState };
        await this.put(accountId, 'view', box.id, JSON.stringify(nextView));
        if (viewPayload?.stateDirty) {
          await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'view' AND cache_key = ?", [accountId, box.id]);
        }
        await this.put(accountId, 'boxes', '', JSON.stringify(await this.reconcileSent(accountId, nextBoxes)));
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Sent cache could not be saved'); }
    });
  }

  async email(accountId: string, emailId: string, includeDirty: boolean = false): Promise<CachedEmail | null> {
    let result: CachedEmail | null = null;
    await this.queue(async () => {
      const payload = await this.get(accountId, 'email', emailId, includeDirty);
      const cached = payload === null ? null : retainedEmail(decodeCachedEmail(payload.payload));
      if (cached && cached.mail.id !== emailId) { throw new Error('Invalid mail cache'); }
      if (cached && cacheIsFresh(cached.bodySavedAt)) {
        const migrated = await this.migrateBody(accountId, cached, payload!);
        cached.stateDirty = payload!.stateDirty; result = await this.hydrate(accountId, cached);
        if (this.files && result) {
          // File awaits do not hold a database snapshot. A separate account
          // handle may remove or replace this row while bytes are read. Accept
          // only the captured record or this reader's own migration CAS.
          const current = await this.db.querySql(`SELECT 1 FROM mail_cache c JOIN accounts a ON a.id = c.account_id
            WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' AND c.cache_key = ?
            AND c.dirty = ? AND (c.payload = ? OR c.payload = ?)`,
            [accountId, emailId, payload!.stateDirty ? 1 : 0, payload!.payload, migrated]);
          try { if (!current.goToFirstRow()) { result = null; } } finally { current.close(); }
        }
      }
    });
    return result;
  }

  // Reader state reconciliation must not copy or decode a long body again.
  async emailSummary(accountId: string, emailId: string): Promise<CachedEmail | null> {
    let result: CachedEmail | null = null;
    await this.queue(async () => {
      const payload = await this.get(accountId, 'email', emailId, true, false);
      if (!payload) { return; }
      const cached = cachedEmailSummary(decodeCachedEmail(payload.payload));
      if (cached.mail.id !== emailId) { throw new Error('Invalid mail cache'); }
      if (cacheIsFresh(cached.savedAt)) { cached.stateDirty = payload.stateDirty; result = cached; }
    });
    return result;
  }

  // Account-scoped conversation index includes fresh summaries and uncertain
  // flags, while expired body bytes are stripped by the normal retention rule.
  async cachedMessages(accountId: string, includeBody: boolean = true): Promise<CachedEmail[]> {
    const result: CachedEmail[] = [];
    await this.queue(async () => {
      const payload = await this.emailPayload(includeBody);
      const rows = await this.db.querySql(`SELECT c.cache_key, ${rdbTextProjection(payload)}, c.dirty, length(CAST((${payload}) AS BLOB)) FROM mail_cache c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' ORDER BY c.cache_key`, [accountId]);
      const stored: StoredCache[] = [];
      try {
        while (rows.goToNextRow()) {
          stored.push({ account: accountId, kind: 'email', key: rows.getString(0), payload: rows.getString(1), dirty: rows.getLong(2), bytes: rows.getLong(3) });
        }
      } finally { rows.close(); }
      for (const record of stored) {
          try {
            const cached = decodeCachedEmail(await this.recordPayload(record, payload));
            if (cached.mail.id !== record.key || !cacheIsFresh(cached.savedAt)) { continue; }
            const retained = includeBody ? retainedEmail(cached) : cachedEmailSummary(cached);
            retained.stateDirty = record.dirty !== 0; retained.summaryOnly = !includeBody || retained.bodySavedAt === null;
            const hydrated = includeBody ? await this.hydrate(accountId, retained) : retained;
            result.push(hydrated || missingCachedEmail(retained));
          } catch (_) { /* One malformed cached record must not hide the rest. */ }
      }
    });
    return result;
  }

  saveView(accountId: string, mailboxId: string, emails: JmapEmail[], nextPosition: number | null = null, queryState?: string, revision: number = MailCache.mutationRevision()): Promise<void> {
    const now = Date.now();
    const copies = emails.map((mail) => cacheEmail(mail, false, null, now).mail);
    const view: CachedView = { version: 1, savedAt: now, mailboxId, ids: copies.map((mail) => mail.id), nextPosition, queryState };
    const payload = JSON.stringify(view); decodeCachedView(payload);
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        // Build the small Message-ID index only when a header actually needs
        // local-body recovery, and share it for the whole page. Full body bytes
        // are read only for a matching local copy, never for every candidate.
        let localIndex: Promise<Map<string, string[]>> | undefined;
        const localBodies: LocalBodyLookup = () => {
          const requested = localIndex || this.localSentBodyIndex(accountId);
          localIndex = requested; return requested;
        };
        for (const mail of copies) { await this.writeEmail(accountId, mail, false, revision, localBodies); }
        const previousPayload = await this.get(accountId, 'view', mailboxId, true);
        const previousView = previousPayload ? decodeCachedView(previousPayload.payload) : null;
        if (previousView && cacheIsFresh(previousView.savedAt)) {
          const retainedIds: string[] = [];
          const fetchedIds = new Set(view.ids);
          const fetchedMessageIds = new Set(copies.flatMap(mail => mail.messageIds.map(id => id.replace(/^<|>$/g, ''))));
          for (const id of previousView.ids) {
            if (fetchedIds.has(id)) { continue; }
            const key = `${accountId}:${id}`;
            if (!id.startsWith('local_sent_') && !id.startsWith('local_archive_') && !MailCache.liveMutations.has(key) && (MailCache.mutationVersions.get(key) || 0) <= revision) { continue; }
            const stored = await this.get(accountId, 'email', id, true);
            if (!stored) { continue; }
            const cached = retainedEmail(decodeCachedEmail(stored.payload));
            if (!cached.mail.mailboxIds.includes(mailboxId) || !cacheIsFresh(cached.savedAt)) { continue; }
            if (id.startsWith('local_sent_') && (!cacheReadyForReading(cached) || cached.mail.messageIds.some(value => fetchedMessageIds.has(value.replace(/^<|>$/g, ''))))) { continue; }
            // A same-Message-ID header does not prove a mapped replacement or
            // contain a downloaded body. Keep the explicit archived offline copy.
            retainedIds.push(id);
          }
          view.ids = retainedIds.concat(view.ids);
        }
        await this.put(accountId, 'view', mailboxId, JSON.stringify(view));
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail cache could not be saved'); }
    });
  }

  async view(accountId: string, mailboxId: string, includeDirty: boolean = false, includeBody: boolean = true): Promise<CachedMailList | null> {
    let result: CachedMailList | null = null;
    await this.queue(async () => {
      const payload = await this.get(accountId, 'view', mailboxId, includeDirty);
      if (payload === null) { return; }
      const view = decodeCachedView(payload.payload);
      if (!cacheIsFresh(view.savedAt)) { return; }
      if (view.mailboxId !== mailboxId) { throw new Error('Invalid mail cache'); }
      const emails: JmapEmail[] = [];
      let stateDirty = payload.stateDirty;
      const emailPayload = await this.emailPayload(includeBody);
      // One native bridge round-trip per message stalls a refreshed folder.
      // Bound SQL parameters and decode each batch in the persisted view order.
      for (let offset = 0; offset < view.ids.length; offset += 64) {
        const ids = view.ids.slice(offset, offset + 64);
        const rows = await this.db.querySql(`SELECT c.cache_key, ${rdbTextProjection(emailPayload)}, c.dirty, length(CAST((${emailPayload}) AS BLOB)) FROM mail_cache c JOIN accounts a ON a.id = c.account_id
          WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' AND c.cache_key IN (${ids.map(() => '?').join(',')}) AND (? = 1 OR c.dirty = 0)`,
          [accountId, ...ids, includeDirty ? 1 : 0]);
        const stored = new Map<string, CachedEmail>();
        const records: StoredCache[] = [];
        try {
          while (rows.goToNextRow()) {
            records.push({ account: accountId, kind: 'email', key: rows.getString(0), payload: rows.getString(1), dirty: rows.getLong(2), bytes: rows.getLong(3) });
          }
        } finally { rows.close(); }
        for (const record of records) {
          const cached = decodeCachedEmail(await this.recordPayload(record, emailPayload));
          cached.stateDirty = record.dirty !== 0; stored.set(record.key, cached);
        }
        for (const emailId of ids) {
          const cached = stored.get(emailId);
          if (!cached) { continue; }
          stateDirty = stateDirty || cached.stateDirty === true;
          const retained = includeBody ? retainedEmail(cached) : cachedEmailSummary(cached);
          const hydrated = includeBody ? await this.hydrate(accountId, retained) : retained;
          const mail = (hydrated || missingCachedEmail(retained)).mail;
          if (mail.id !== emailId) { throw new Error('Invalid mail cache'); }
          if (mail.mailboxIds.includes(mailboxId)) { emails.push(mail); }
        }
      }
      result = { savedAt: view.savedAt, emails, nextPosition: view.nextPosition ?? null, queryState: view.queryState, stateDirty };
    });
    return result;
  }

  // Persist this before sending a mutation. Default reads exclude uncertain
  // flags/folders; explicit saved-copy reads retain the immutable downloaded
  // body and expose stateDirty so the UI can disable mutations until refresh.
  markDirty(accountId: string, emailId: string): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        await this.badges?.mutationStarted(accountId);
        await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, emailId]);
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
  }

  // Only call after a server-verified acknowledgement. Flag changes do not
  // change message content or renew its download/retention timestamps.
  updateKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean, adjustCounts: boolean = false): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const stored = await this.get(accountId, 'email', emailId, true);
        if (stored !== null) {
          const cached = decodeCachedEmail(stored.payload);
          if (cached.mail.id !== emailId) { throw new Error('Invalid mail cache'); }
          const previous = shallowCopyEmail(cached.mail);
          const changed = cached.mail.keywords.includes(keyword) !== enabled;
          cached.mail.keywords = cached.mail.keywords.filter(value => value !== keyword);
          if (enabled) { cached.mail.keywords.push(keyword); }
          if (adjustCounts) { await this.badges?.messageChanged(accountId, previous, cached.mail); }
          else { await this.badges?.mutationStarted(accountId); }
          if (adjustCounts && changed && keyword === '$seen') {
            const storedBoxes = await this.get(accountId, 'boxes', '');
            if (storedBoxes) {
              const boxes = decodeCachedBoxes(storedBoxes.payload);
              for (const box of boxes.boxes) {
                if (cached.mail.mailboxIds.includes(box.id) && box.countsKnown !== false) {
                  box.unreadEmails = Math.max(0, box.unreadEmails + (enabled ? -1 : 1));
                }
              }
              await this.put(accountId, 'boxes', '', JSON.stringify(boxes));
            }
          }
          await this.put(accountId, 'email', emailId, JSON.stringify(cached));
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw (error as Error); }
    });
  }

  beginMutation(accountId: string, emailId: string): Promise<boolean> {
    let started = false;
    return this.queue(async () => {
      const stored = await this.get(accountId, 'email', emailId, true);
      if (!stored || stored.stateDirty) { return; }
      this.db.beginTransaction();
      try {
        await this.badges?.mutationStarted(accountId);
        await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, emailId]);
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
      const key = `${accountId}:${emailId}`;
      MailCache.liveMutations.add(key); MailCache.mutationVersions.set(key, ++MailCache.mutationClock);
      started = true;
    }).then(() => started);
  }

  // Folder acknowledgements update only mutable membership. A move never
  // replaces or re-dates an already downloaded body.
  updateMailboxes(accountId: string, emailId: string, mailboxIds: string[]): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const stored = await this.get(accountId, 'email', emailId, true);
        if (stored) {
          const cached = decodeCachedEmail(stored.payload);
          const previous = cached.mail.mailboxIds;
          const previousMail = shallowCopyEmail(cached.mail);
          cached.mail.mailboxIds = mailboxIds.slice();
          await this.badges?.messageChanged(accountId, previousMail, cached.mail);
          await this.put(accountId, 'email', emailId, JSON.stringify(cached));
          for (const mailboxId of mailboxIds) {
            if (previous.includes(mailboxId)) { continue; }
            const storedView = await this.get(accountId, 'view', mailboxId, true);
            if (!storedView) { continue; }
            const view = decodeCachedView(storedView.payload);
            if (!view.ids.includes(emailId)) { view.ids.unshift(emailId); }
            await this.put(accountId, 'view', mailboxId, JSON.stringify(view));
          }
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw (error as Error); }
    });
  }

  // UID MOVE changes the server identity. Keep the original immutable content
  // origin for prepared HTML, pictures and attachment files, without reading or
  // rewriting any body/image bytes. Only a verified protocol result calls this.
  moveEmailIdentity(accountId: string, oldId: string, newId: string, mailboxIds: string[], archiveMailbox?: JmapMailbox): Promise<void> {
    if (oldId === newId) { return this.updateMailboxes(accountId, oldId, mailboxIds); }
    if (![oldId, newId, ...mailboxIds].every(id => /^[A-Za-z0-9_-]{1,4096}$/.test(id)) || mailboxIds.length === 0) {
      return Promise.reject(new Error('Invalid moved message identity'));
    }
    let confirmedArchive: JmapMailbox | undefined;
    if (archiveMailbox !== undefined) {
      try {
        // Snapshot and validate the receipt before yielding. Folder creation
        // hints alone never create a locally visible destination.
        const receipt = decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: Date.now(), boxes: [archiveMailbox] } as CachedBoxes));
        confirmedArchive = receipt.boxes[0];
        if (!['archive', 'trash'].includes(confirmedArchive.role || '') || !mailboxIds.includes(confirmedArchive.id)) { throw new Error('Invalid archive receipt'); }
      } catch (_) { return Promise.reject(new Error('Invalid archive mailbox receipt')); }
    }
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const stored = await this.get(accountId, 'email', oldId, true);
        if (!stored) { throw new Error('Moved message cache is unavailable'); }
        const source = decodeCachedEmail(stored.payload), previousMail = shallowCopyEmail(source.mail);
        if (source.mail.id !== oldId || !this.validBodyOwner(accountId, source)) { throw new Error('Invalid moved message cache'); }
        const targetPayload = await this.get(accountId, 'email', newId, true);
        const target = targetPayload ? decodeCachedEmail(targetPayload.payload) : null;
        const useTarget = target && cacheIsFresh(target.bodySavedAt) &&
          (source.bodySavedAt === null || target.bodySavedAt! >= source.bodySavedAt);
        const cached = useTarget ? target! : source;
        const attachmentOrigins = [newId, oldId, cached.mail.cachedSourceId || cached.mail.id,
          source.mail.cachedSourceId || oldId, target?.mail.cachedSourceId || newId]
          .concat(attachmentCacheSources(source.mail), target ? attachmentCacheSources(target.mail) : []);
        cached.mail.cachedAttachmentSourceIds = Array.from(new Set(attachmentOrigins)).slice(0, 16);
        cached.mail.cachedSourceId = cached.mail.cachedSourceId || cached.mail.id;
        if (cached.mail.threadId === cached.mail.id) { cached.mail.threadId = newId; }
        cached.mail.id = newId; cached.mail.mailboxIds = mailboxIds.slice();
        if (targetPayload?.stateDirty && target) { cached.mail.keywords = target.mail.keywords.slice(); }
        if (newId.startsWith('local_')) { cached.mail.maySetSeen = false; cached.mail.maySetKeywords = false; }
        if (!this.validBodyOwner(accountId, cached)) { throw new Error('Invalid moved body owner'); }
        // Read each view once before writing. Pooled RDB readers need not see
        // uncommitted writes on another handle.
        const views: CachedView[] = [];
        for (const mailboxId of Array.from(new Set(previousMail.mailboxIds.concat(mailboxIds)))) {
          const viewPayload = await this.get(accountId, 'view', mailboxId, true);
          if (!viewPayload && !mailboxIds.includes(mailboxId)) { continue; }
          const view: CachedView = viewPayload ? decodeCachedView(viewPayload.payload) :
            { version: 1, savedAt: Date.now(), mailboxId, ids: [] };
          view.ids = view.ids.filter(id => id !== oldId && id !== newId);
          if (mailboxIds.includes(mailboxId)) { view.ids.unshift(newId); }
          views.push(view);
        }
        let boxes: CachedBoxes | null = null;
        let boxesDirty = false;
        if (confirmedArchive) {
          const storedBoxes = await this.get(accountId, 'boxes', '', true);
          boxes = storedBoxes ? decodeCachedBoxes(storedBoxes.payload) :
            { version: 1, savedAt: Date.now(), boxes: [], roleRevision: MAILBOX_ROLE_REVISION };
          boxesDirty = storedBoxes?.stateDirty ?? false;
          let found = false;
          for (const box of boxes.boxes) {
            if (box.id === confirmedArchive.id) { box.role = confirmedArchive.role; found = true; }
            else if (box.role === confirmedArchive.role) { box.role = null; }
            if (confirmedArchive.role === 'archive' && box.role === 'inbox') { box.archiveDestinationId = undefined; box.archiveDestinationName = undefined; }
          }
          if (!found) {
            // MOVE proves the destination exists, but does not provide a full
            // mailbox count. Existing target counts/permissions stay intact.
            const added: JmapMailbox = { id: confirmedArchive.id, name: confirmedArchive.name,
              parentId: confirmedArchive.parentId, role: confirmedArchive.role, sortOrder: confirmedArchive.sortOrder,
              totalEmails: 0, unreadEmails: 0, countsKnown: false,
              maySetSeen: confirmedArchive.maySetSeen, maySetKeywords: confirmedArchive.maySetKeywords,
              mayAddItems: confirmedArchive.mayAddItems, mayRemoveItems: confirmedArchive.mayRemoveItems };
            boxes.boxes.push(added);
          }
        }
        await this.badges?.messageChanged(accountId, previousMail, cached.mail);
        await this.put(accountId, 'email', newId, JSON.stringify(cached));
        if (targetPayload?.stateDirty) {
          await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, newId]);
        }
        for (const view of views) { await this.put(accountId, 'view', view.mailboxId, JSON.stringify(view)); }
        if (boxes) {
          await this.put(accountId, 'boxes', '', JSON.stringify(boxes));
          if (boxesDirty) { await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'boxes' AND cache_key = ''", [accountId]); }
        }
        await this.db.executeSql("DELETE FROM mail_cache WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, oldId]);
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
      const oldKey = `${accountId}:${oldId}`, newKey = `${accountId}:${newId}`;
      MailCache.movedIdentities.add(oldKey);
      MailCache.mutationVersions.set(oldKey, ++MailCache.mutationClock);
      MailCache.mutationVersions.set(newKey, ++MailCache.mutationClock);
      if (confirmedArchive) { MailCache.mailboxMutations.set(accountId, ++MailCache.mutationClock); }
    });
  }

  forgetEmail(accountId: string, emailId: string): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const stored = await this.get(accountId, 'email', emailId, true);
        // A missing reader body is not a confirmed local delete. The latest
        // server total may already exclude this retained header, so only
        // invalidate an in-flight snapshot rather than subtracting twice.
        if (stored) { await this.badges?.mutationStarted(accountId); }
        await this.db.executeSql("DELETE FROM mail_cache WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, emailId]);
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
  }
}
