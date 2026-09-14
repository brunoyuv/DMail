// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { MAIL_RETENTION_MS } from './MailCacheModel';

type Queue = (operation: () => Promise<void>) => Promise<void>;
export interface CachedPicture { data: ArrayBuffer; mimeType: string; }
interface StoredPicture { message: string; url: string; size: number; }
interface PictureFlight { task: Promise<CachedPicture | null>; refresh: boolean; }

const MAX_PICTURE_BYTES = 8 * 1024 * 1024;
const ACCOUNT_PICTURE_BYTES = 128 * 1024 * 1024;

// Consent belongs to this message in this account, independently of the
// short-lived bytes. Both are inside the same encrypted database as the mail.
export class PictureCache {
  private db: relationalStore.RdbStore;
  private queue: Queue;
  // Instance ownership isolates different account databases and test stores.
  private flights: Map<string, PictureFlight> = new Map();
  private activeRequests: number = 0;
  private waiting: Array<() => void> = [];

  constructor(db: relationalStore.RdbStore, queue: Queue) { this.db = db; this.queue = queue; }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS picture_consent (account_id TEXT NOT NULL, message_key TEXT NOT NULL, PRIMARY KEY (account_id, message_key))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS picture_cache (account_id TEXT NOT NULL, message_key TEXT NOT NULL, url TEXT NOT NULL, mime_type TEXT NOT NULL, data BLOB NOT NULL, saved_at INTEGER NOT NULL, PRIMARY KEY (account_id, message_key, url))');
    const now = Date.now();
    await db.executeSql('DELETE FROM picture_cache WHERE saved_at <= ? OR saved_at > ?', [now - MAIL_RETENTION_MS, now]);
  }

  private validKey(accountId: string, messageKey: string): boolean {
    return accountId.length > 0 && accountId.length <= 4096 && messageKey.length > 0 && messageKey.length <= 4096;
  }

  async allowed(accountId: string, messageKey: string): Promise<boolean> {
    if (!this.validKey(accountId, messageKey)) { return false; }
    let result = false;
    await this.queue(async () => {
      const rows = await this.db.querySql("SELECT 1 FROM picture_consent c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.message_key = ?", [accountId, messageKey]);
      try { result = rows.goToFirstRow(); } finally { rows.close(); }
    });
    return result;
  }

  allow(accountId: string, messageKey: string): Promise<void> {
    if (!this.validKey(accountId, messageKey)) { return Promise.reject(new Error('Invalid picture identity')); }
    return this.queue(async () => {
      await this.db.executeSql("INSERT OR IGNORE INTO picture_consent (account_id, message_key) SELECT id, ? FROM accounts WHERE id = ? AND status = 'ready'", [messageKey, accountId]);
    });
  }

  load(accountId: string, messageKey: string, source: string, refresh: boolean = false): Promise<CachedPicture | null> {
    // Never accept credential-bearing URLs, local files, or other schemes.
    if (!this.validKey(accountId, messageKey) || source.length > 8192 ||
      !/^https?:\/\/[^\s\\\/?#@]+(?:[\/?#]|$)/i.test(source) || /[\u0000-\u0020\u007f\\]/.test(source)) {
      return Promise.resolve(null);
    }
    const key = JSON.stringify([accountId, messageKey, source]);
    const existing = this.flights.get(key);
    if (existing && (!refresh || existing.refresh)) { return existing.task; }
    // A user refresh waits for an older load before replacing its bytes. A
    // second refresh joins this flight, so old responses cannot win the race.
    const task = (existing ? existing.task.then(() => this.loadPicture(accountId, messageKey, source, true)) :
      this.loadPicture(accountId, messageKey, source, refresh)).catch((): null => null);
    const flight: PictureFlight = { task, refresh };
    this.flights.set(key, flight);
    task.then(() => { if (this.flights.get(key) === flight) { this.flights.delete(key); } });
    return task;
  }

  private async cached(accountId: string, messageKey: string, source: string): Promise<CachedPicture | null> {
    let picture: CachedPicture | null = null;
    await this.queue(async () => {
      const now = Date.now();
      const rows = await this.db.querySql("SELECT p.data, p.mime_type FROM picture_cache p JOIN picture_consent c ON c.account_id = p.account_id AND c.message_key = p.message_key JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ? AND p.url = ? AND p.saved_at > ? AND p.saved_at <= ?", [accountId, messageKey, source, now - MAIL_RETENTION_MS, now]);
      try {
        if (rows.goToFirstRow()) {
          const bytes = rows.getBlob(0);
          if (bytes.byteLength > 0 && bytes.byteLength <= MAX_PICTURE_BYTES) {
            // Copy the RDB view before closing the result set.
            const value: CachedPicture = { data: new Uint8Array(bytes).buffer as ArrayBuffer, mimeType: rows.getString(1) };
            picture = value;
          }
        }
      } finally { rows.close(); }
    });
    return picture;
  }

  private async acquire(): Promise<void> {
    if (this.activeRequests < 4) { this.activeRequests++; return; }
    await new Promise<void>(resolve => { this.waiting.push(resolve); });
  }

  private release(): void {
    const next = this.waiting.shift();
    if (next) { next(); } else { this.activeRequests--; }
  }

  private async loadPicture(accountId: string, messageKey: string, source: string, refresh: boolean): Promise<CachedPicture | null> {
    if (!await this.allowed(accountId, messageKey)) { return null; }
    const cached = await this.cached(accountId, messageKey, source);
    if (cached && !refresh) { return cached; }
    await this.acquire();
    try {
      // The account may have been removed while waiting behind other images.
      if (!await this.allowed(accountId, messageKey)) { return null; }
      const request = http.createHttp();
      try {
        // Each request is new, so no cookie jar, mailbox authorization, or
        // referring document is shared. The SDK bounds response bytes itself.
        const response = await request.request(source, {
          method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false, header: { 'Accept': 'image/*' },
          connectTimeout: 10000, readTimeout: 20000, maxLimit: MAX_PICTURE_BYTES
        });
        if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer) ||
          response.result.byteLength === 0 || response.result.byteLength > MAX_PICTURE_BYTES) { return cached; }
        const headers = response.header as Record<string, string>;
        const typeKey = Object.keys(headers).find(key => key.toLowerCase() === 'content-type');
        const mimeType = typeKey ? String(headers[typeKey]).split(';')[0].trim().toLowerCase() : '';
        if (!/^image\/[a-z0-9.+-]{1,64}$/.test(mimeType)) { return cached; }
        const picture: CachedPicture = { data: response.result, mimeType };
        await this.save(accountId, messageKey, source, picture);
        return picture;
      } catch (_) {
        // Explicit refresh never deletes a usable offline copy or its consent.
        return cached;
      } finally { request.destroy(); }
    } finally { this.release(); }
  }

  private save(accountId: string, messageKey: string, source: string, picture: CachedPicture): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const now = Date.now();
        await this.db.executeSql('DELETE FROM picture_cache WHERE account_id = ? AND (saved_at <= ? OR saved_at > ?)', [accountId, now - MAIL_RETENTION_MS, now]);
        // The consent and ready-account join also prevents a late HTTP result
        // from resurrecting data after account deletion.
        await this.db.executeSql("INSERT OR REPLACE INTO picture_cache (account_id, message_key, url, mime_type, data, saved_at) SELECT c.account_id, c.message_key, ?, ?, ?, ? FROM picture_consent c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.message_key = ?", [source, picture.mimeType, new Uint8Array(picture.data), now, accountId, messageKey]);
        const rows = await this.db.querySql('SELECT message_key, url, length(data) FROM picture_cache WHERE account_id = ? ORDER BY saved_at ASC, message_key, url', [accountId]);
        const stored: StoredPicture[] = []; let total = 0;
        try { while (rows.goToNextRow()) {
          const size = rows.getLong(2); total += size;
          stored.push({ message: rows.getString(0), url: rows.getString(1), size });
        } } finally { rows.close(); }
        for (const entry of stored) {
          if (total <= ACCOUNT_PICTURE_BYTES) { break; }
          await this.db.executeSql('DELETE FROM picture_cache WHERE account_id = ? AND message_key = ? AND url = ?', [accountId, entry.message, entry.url]);
          total -= entry.size;
        }
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Picture cache could not be saved'); }
    });
  }

  async whenIdle(): Promise<void> {
    while (this.flights.size > 0) { await Promise.all(Array.from(this.flights.values()).map(flight => flight.task)); }
  }
}
