// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { UnreadBadgeStore } from './UnreadBadgeStore';
import { JmapEmail, JmapMailbox, JmapKeyword } from '../mail/jmap/JmapClient';
import { CachedEmail, CachedView, CachedBoxes, CachedMailList, cacheEmail,
  decodeCachedEmail, decodeCachedView, decodeCachedBoxes, cacheIsFresh, retainedEmail, cacheReadyForReading, MAILBOX_ROLE_REVISION } from './MailCacheModel';
import { prependSentMessage, serverSentMailbox, sentMailbox, LOCAL_SENT_MAILBOX } from '../mail/smtp/SentMail';

type Queue = (operation: () => Promise<void>) => Promise<void>;
interface StoredCache { account: string; kind: string; key: string; payload: string; }
interface StoredPayload { payload: string; stateDirty: boolean; }

// Shares the encrypted account database and its serialized operation queue.
// The account join hides pending/deleting rows during crash recovery.
export class MailCache {
  private static mutationClock: number = 0;
  private static mutationVersions: Map<string, number> = new Map();
  private static liveMutations: Set<string> = new Set();
  static mutationRevision(): number { return MailCache.mutationClock; }
  endMutation(accountId: string, emailId: string): void {
    const key = `${accountId}:${emailId}`;
    if (MailCache.liveMutations.delete(key)) { MailCache.mutationVersions.set(key, ++MailCache.mutationClock); }
  }

  private db: relationalStore.RdbStore;
  private queue: Queue;
  private badges?: UnreadBadgeStore;
  constructor(db: relationalStore.RdbStore, queue: Queue, badges?: UnreadBadgeStore) { this.db = db; this.queue = queue; this.badges = badges; }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS mail_cache (account_id TEXT NOT NULL, kind TEXT NOT NULL, cache_key TEXT NOT NULL, payload TEXT NOT NULL, dirty INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (account_id, kind, cache_key))');
    const rows = await db.querySql('SELECT account_id, kind, cache_key, payload FROM mail_cache');
    const records: StoredCache[] = [];
    try { while (rows.goToNextRow()) { records.push({ account: rows.getString(0), kind: rows.getString(1), key: rows.getString(2), payload: rows.getString(3) }); } }
    finally { rows.close(); }
    for (const record of records) {
      let fresh = false; let payload = record.payload;
      try {
        if (record.kind === 'email') {
          const cached = decodeCachedEmail(payload); fresh = cacheIsFresh(cached.savedAt);
          payload = JSON.stringify(retainedEmail(cached));
        } else { fresh = cacheIsFresh(record.kind === 'view' ? decodeCachedView(payload).savedAt : decodeCachedBoxes(payload).savedAt); }
      } catch (_) {}
      const keys: relationalStore.ValueType[] = [record.account, record.kind, record.key];
      if (!fresh) { await db.executeSql('DELETE FROM mail_cache WHERE account_id = ? AND kind = ? AND cache_key = ?', keys); }
      else if (payload !== record.payload) { await db.executeSql('UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = ? AND cache_key = ?', [payload, ...keys]); }
    }
  }

  private async get(accountId: string, kind: string, key: string, includeDirty: boolean = false): Promise<StoredPayload | null> {
    const rows = await this.db.querySql("SELECT c.payload, c.dirty FROM mail_cache c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = ? AND c.cache_key = ? AND (? = 1 OR c.dirty = 0)",
      [accountId, kind, key, includeDirty ? 1 : 0]);
    try { return rows.goToFirstRow() ? { payload: rows.getString(0), stateDirty: rows.getLong(1) !== 0 } : null; }
    finally { rows.close(); }
  }

  private async put(accountId: string, kind: string, key: string, payload: string): Promise<void> {
    await this.db.executeSql("INSERT OR REPLACE INTO mail_cache (account_id, kind, cache_key, payload, dirty) SELECT ?, ?, ?, ?, 0 WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
      [accountId, kind, key, payload, accountId]);
  }

  saveBoxes(accountId: string, boxes: JmapMailbox[], readOnly?: boolean): Promise<void> {
    const value = decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: Date.now(), boxes, readOnly, roleRevision: MAILBOX_ROLE_REVISION } as CachedBoxes));
    return this.queue(async () => {
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
    const rows = await this.db.querySql("SELECT cache_key, payload FROM mail_cache WHERE account_id = ? AND kind = 'email'", [accountId]);
    const moved: CachedEmail[] = [];
    try {
      while (rows.goToNextRow()) {
        const cached = decodeCachedEmail(rows.getString(1));
        if (!cacheIsFresh(cached.savedAt) || !cached.mail.mailboxIds.includes(LOCAL_SENT_MAILBOX)) { continue; }
        cached.mail.mailboxIds = Array.from(new Set(cached.mail.mailboxIds.map(id => id === LOCAL_SENT_MAILBOX ? target.id : id)));
        moved.push(cached);
      }
    } finally { rows.close(); }
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
          const previous = decodeCachedEmail(JSON.stringify(body)); previous.mail.id = server.mail.id;
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

  private async writeEmail(accountId: string, mail: JmapEmail, fullBody: boolean, revision: number = MailCache.mutationRevision()): Promise<void> {
    const payload = await this.get(accountId, 'email', mail.id, true);
    let previous = payload === null ? null : decodeCachedEmail(payload.payload);
    const previousState = previous;
    // SMTP and the server's Sent UID are different local identities for the
    // same MIME Message-ID. Reuse the confirmed local body when headers arrive.
    if (!fullBody && !cacheReadyForReading(previous) && mail.messageIds.length > 0) {
      const rows = await this.db.querySql("SELECT payload FROM mail_cache WHERE account_id = ? AND kind = 'email' AND cache_key LIKE 'local_sent_%'", [accountId]);
      try {
        while (rows.goToNextRow()) {
          const candidate = retainedEmail(decodeCachedEmail(rows.getString(0)));
          if (cacheReadyForReading(candidate) && candidate.mail.messageIds.some(id => mail.messageIds.some(value => value.replace(/^<|>$/g, '') === id.replace(/^<|>$/g, '')))) {
            candidate.mail.id = mail.id; previous = candidate; break;
          }
        }
      } finally { rows.close(); }
    }
    const value = cacheEmail(mail, fullBody, previous, Date.now());
    const key = `${accountId}:${mail.id}`;
    const preserveState = previousState !== null && (MailCache.liveMutations.has(key) || (MailCache.mutationVersions.get(key) || 0) > revision);
    if (preserveState && previousState) { value.mail.keywords = previousState.mail.keywords; value.mail.mailboxIds = previousState.mail.mailboxIds; }
    await this.put(accountId, 'email', mail.id, JSON.stringify(value));
    if (preserveState && payload?.stateDirty) {
      await this.db.executeSql("UPDATE mail_cache SET dirty = 1 WHERE account_id = ? AND kind = 'email' AND cache_key = ?", [accountId, mail.id]);
    }
  }

  saveEmail(accountId: string, mail: JmapEmail, revision: number = MailCache.mutationRevision()): Promise<void> {
    const copy = cacheEmail(mail, true, null, Date.now()).mail;
    return this.queue(() => this.writeEmail(accountId, copy, true, revision));
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
        cached.stateDirty = payload!.stateDirty; result = cached;
      }
    });
    return result;
  }

  // Account-scoped conversation index includes fresh summaries and uncertain
  // flags, while expired body bytes are stripped by the normal retention rule.
  async cachedMessages(accountId: string): Promise<CachedEmail[]> {
    const result: CachedEmail[] = [];
    await this.queue(async () => {
      const rows = await this.db.querySql("SELECT c.cache_key, c.payload, c.dirty FROM mail_cache c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.kind = 'email' ORDER BY c.cache_key", [accountId]);
      try {
        while (rows.goToNextRow()) {
          try {
            const cached = decodeCachedEmail(rows.getString(1));
            if (cached.mail.id !== rows.getString(0) || !cacheIsFresh(cached.savedAt)) { continue; }
            const retained = retainedEmail(cached);
            retained.stateDirty = rows.getLong(2) !== 0; retained.summaryOnly = retained.bodySavedAt === null;
            result.push(retained);
          } catch (_) { /* One malformed cached record must not hide the rest. */ }
        }
      } finally { rows.close(); }
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
        for (const mail of copies) { await this.writeEmail(accountId, mail, false, revision); }
        const previousPayload = await this.get(accountId, 'view', mailboxId, true);
        const previousView = previousPayload ? decodeCachedView(previousPayload.payload) : null;
        if (previousView && cacheIsFresh(previousView.savedAt)) {
          const retainedIds: string[] = [];
          const fetchedMessageIds = copies.flatMap(mail => mail.messageIds.map(id => id.replace(/^<|>$/g, '')));
          for (const id of previousView.ids) {
            if (view.ids.includes(id)) { continue; }
            const key = `${accountId}:${id}`;
            if (!id.startsWith('local_sent_') && !MailCache.liveMutations.has(key) && (MailCache.mutationVersions.get(key) || 0) <= revision) { continue; }
            const stored = await this.get(accountId, 'email', id, true);
            if (!stored) { continue; }
            const cached = retainedEmail(decodeCachedEmail(stored.payload));
            if (!cached.mail.mailboxIds.includes(mailboxId) || !cacheIsFresh(cached.savedAt)) { continue; }
            if (id.startsWith('local_sent_') && (!cacheReadyForReading(cached) || cached.mail.messageIds.some(value => fetchedMessageIds.includes(value.replace(/^<|>$/g, ''))))) { continue; }
            retainedIds.push(id);
          }
          view.ids = retainedIds.concat(view.ids);
        }
        await this.put(accountId, 'view', mailboxId, JSON.stringify(view));
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Mail cache could not be saved'); }
    });
  }

  async view(accountId: string, mailboxId: string, includeDirty: boolean = false): Promise<CachedMailList | null> {
    let result: CachedMailList | null = null;
    await this.queue(async () => {
      const payload = await this.get(accountId, 'view', mailboxId, includeDirty);
      if (payload === null) { return; }
      const view = decodeCachedView(payload.payload);
      if (!cacheIsFresh(view.savedAt)) { return; }
      if (view.mailboxId !== mailboxId) { throw new Error('Invalid mail cache'); }
      const emails: JmapEmail[] = [];
      let stateDirty = payload.stateDirty;
      for (const emailId of view.ids) {
        const stored = await this.get(accountId, 'email', emailId, includeDirty);
        if (stored === null) { continue; }
        stateDirty = stateDirty || stored.stateDirty;
        const mail = decodeCachedEmail(stored.payload).mail;
        if (mail.id !== emailId) { throw new Error('Invalid mail cache'); }
        if (mail.mailboxIds.includes(mailboxId)) { emails.push(mail); }
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
          const previous = cacheEmail(cached.mail, false, null, cached.savedAt).mail;
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
          const previousMail = cacheEmail(cached.mail, false, null, cached.savedAt).mail;
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
