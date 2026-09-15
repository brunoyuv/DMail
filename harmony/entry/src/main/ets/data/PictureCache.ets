// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { MAIL_RETENTION_MS } from './MailCacheModel';
import { pictureMimeType } from './PictureData';

type Queue = (operation: () => Promise<void>) => Promise<void>;
export interface CachedPicture { data: ArrayBuffer; mimeType: string; }
export type PictureFailure = '' | 'address' | 'consent' | 'storage' | 'network' | 'server' | 'format' | 'size';
export interface PictureLoadResult { picture: CachedPicture | null; failure: PictureFailure; status: number; }
export interface SnapshotPicture extends PictureLoadResult { url: string; }
export interface PictureSnapshotState { attempted: boolean; resources: SnapshotPicture[]; }
export interface PictureSnapshotScope { active: () => boolean; deadline: number; permitted?: () => Promise<boolean>; revoked?: boolean; }
export interface PictureSnapshotWindow { owner: string; generation: number; foregroundRevision: number; deadline: number; scope?: PictureSnapshotScope; }
interface StoredSnapshotPicture { url: string; failure: PictureFailure; status: number; }
interface StoredPicture { message: string; url: string; size: number; }
interface PictureFlight {
  task: Promise<CachedPicture | null>; result: Promise<PictureLoadResult>; refresh: boolean;
  generation: number; foregroundRevision: number; scope?: PictureSnapshotScope;
}
interface PictureNetworkError { code?: number; }

function pictureResult(picture: CachedPicture | null, failure: PictureFailure = '', status: number = 0): PictureLoadResult {
  return { picture, failure, status };
}

const MAX_PICTURE_BYTES = 8 * 1024 * 1024;
const ACCOUNT_PICTURE_BYTES = 128 * 1024 * 1024;
export const MAX_SNAPSHOT_PICTURES = 256;
export const MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024;

// Consent belongs to this message in this account, independently of the
// short-lived bytes. Both are inside the same encrypted database as the mail.
export class PictureCache {
  private static foreground: boolean = true;
  private static foregroundRevision: number = 0;
  private db: relationalStore.RdbStore;
  private queue: Queue;
  // Instance ownership isolates different account databases and test stores.
  private flights: Map<string, PictureFlight> = new Map();
  private generations: Map<string, number> = new Map();
  private activeRequests: number = 0;
  private waiting: Array<() => void> = [];
  private snapshotTasks: Set<Promise<void>> = new Set();

  constructor(db: relationalStore.RdbStore, queue: Queue) { this.db = db; this.queue = queue; }

  static setForeground(foreground: boolean): void {
    if (PictureCache.foreground === foreground) { return; }
    PictureCache.foreground = foreground; ++PictureCache.foregroundRevision;
    AppStorage.setOrCreate('mailPictureForeground', foreground);
  }

  cancelPending(accountId: string, messageKey: string): void {
    const owner = JSON.stringify([accountId, messageKey]);
    this.generations.set(owner, (this.generations.get(owner) || 0) + 1);
  }

  private current(owner: string, generation: number, foregroundRevision: number, scope?: PictureSnapshotScope): boolean {
    return generation === (this.generations.get(owner) || 0) && (scope ? !scope.revoked && scope.active() && Date.now() < scope.deadline :
      PictureCache.foreground && foregroundRevision === PictureCache.foregroundRevision);
  }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS picture_consent (account_id TEXT NOT NULL, message_key TEXT NOT NULL, PRIMARY KEY (account_id, message_key))');
    await db.executeSql('CREATE TABLE IF NOT EXISTS picture_cache (account_id TEXT NOT NULL, message_key TEXT NOT NULL, url TEXT NOT NULL, mime_type TEXT NOT NULL, data BLOB NOT NULL, saved_at INTEGER NOT NULL, PRIMARY KEY (account_id, message_key, url))');
    await db.executeSql('CREATE INDEX IF NOT EXISTS picture_cache_expiry ON picture_cache (account_id, saved_at, message_key, url)');
    await db.executeSql('CREATE TABLE IF NOT EXISTS picture_snapshot (account_id TEXT NOT NULL, message_key TEXT NOT NULL, manifest TEXT NOT NULL, PRIMARY KEY (account_id, message_key))');
    const now = Date.now();
    await db.executeSql('DELETE FROM picture_cache WHERE saved_at <= ? OR saved_at > ?', [now - MAIL_RETENTION_MS, now]);
    // Keep completed attempts after image expiry: reopening must not silently
    // restart failed or evicted downloads. Account deletion removes the marker.
    await db.executeSql('DELETE FROM picture_snapshot WHERE NOT EXISTS (SELECT 1 FROM accounts WHERE accounts.id = picture_snapshot.account_id)');
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
    return this.flight(accountId, messageKey, source, refresh).task;
  }

  loadWithStatus(accountId: string, messageKey: string, source: string, refresh: boolean = false): Promise<PictureLoadResult> {
    return this.flight(accountId, messageKey, source, refresh).result;
  }

  snapshotWindow(accountId: string, messageKey: string, deadline: number, scope?: PictureSnapshotScope): PictureSnapshotWindow {
    const owner = JSON.stringify([accountId, messageKey]);
    return { owner, generation: this.generations.get(owner) || 0, foregroundRevision: PictureCache.foregroundRevision,
      deadline: Math.min(deadline, scope?.deadline ?? deadline), scope };
  }

  snapshotCurrent(window: PictureSnapshotWindow): boolean {
    return this.current(window.owner, window.generation, window.foregroundRevision, window.scope);
  }

  loadForSnapshot(accountId: string, messageKey: string, source: string, window: PictureSnapshotWindow): Promise<PictureLoadResult> {
    if (window.owner !== JSON.stringify([accountId, messageKey]) || !this.snapshotCurrent(window)) {
      return Promise.resolve(pictureResult(null));
    }
    return this.flight(accountId, messageKey, source, false, window.deadline, window.scope).result;
  }

  async snapshotAttempted(accountId: string, messageKey: string): Promise<boolean> {
    if (!this.validKey(accountId, messageKey)) { throw new Error('Invalid picture identity'); }
    let attempted = false;
    await this.queue(async () => {
      const rows = await this.db.querySql("SELECT 1 FROM picture_snapshot p JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ?", [accountId, messageKey]);
      try { attempted = rows.goToFirstRow(); } finally { rows.close(); }
    });
    return attempted;
  }

  trackSnapshot(task: Promise<void>): void {
    this.snapshotTasks.add(task);
    task.then(() => this.snapshotTasks.delete(task), () => this.snapshotTasks.delete(task));
  }

  async readSnapshot(accountId: string, messageKey: string, urls: string[]): Promise<PictureSnapshotState> {
    if (!this.validKey(accountId, messageKey) || urls.length > MAX_SNAPSHOT_PICTURES || urls.some(url => url.length > 8192)) {
      throw new Error('Invalid picture snapshot');
    }
    const resources: SnapshotPicture[] = urls.map((url: string): SnapshotPicture => ({ url, picture: null, failure: 'network', status: 0 }));
    let attempted = false;
    await this.queue(async () => {
      const rows = await this.db.querySql("SELECT p.manifest FROM picture_snapshot p JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ?", [accountId, messageKey]);
      try {
        if (rows.goToFirstRow()) {
          attempted = true;
          const source = rows.getString(0);
          if (source.length > 3 * 1024 * 1024) { throw new Error('Invalid picture snapshot'); }
          const stored = JSON.parse(source) as StoredSnapshotPicture[];
          if (!Array.isArray(stored) || stored.length > MAX_SNAPSHOT_PICTURES) { throw new Error('Invalid picture snapshot'); }
          const failures = new Map<string, StoredSnapshotPicture>();
          for (const entry of stored) {
            if (typeof entry.url !== 'string' || entry.url.length > 8192 ||
              !['', 'address', 'consent', 'storage', 'network', 'server', 'format', 'size'].includes(entry.failure) ||
              !Number.isInteger(entry.status) || entry.status < 0 || entry.status > 599) { throw new Error('Invalid picture snapshot'); }
            failures.set(entry.url, entry);
          }
          for (const resource of resources) {
            const entry = failures.get(resource.url);
            if (entry) { resource.failure = entry.failure || 'network'; resource.status = entry.status; }
          }
        }
      } finally { rows.close(); }
      if (urls.length === 0) { return; }
      const now = Date.now(), positions = new Map<string, number>();
      urls.forEach((url, index) => positions.set(url, index));
      const placeholders = urls.map(() => '?').join(',');
      const pictures = await this.db.querySql(`SELECT p.url, length(p.data), p.data, p.mime_type FROM picture_cache p JOIN picture_consent c ON c.account_id = p.account_id AND c.message_key = p.message_key JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ? AND p.url IN (${placeholders}) AND p.saved_at > ? AND p.saved_at <= ? ORDER BY p.url`,
        [accountId, messageKey, ...urls, now - MAIL_RETENTION_MS, now]);
      let total = 0;
      try { while (pictures.goToNextRow()) {
        const index = positions.get(pictures.getString(0));
        if (index === undefined) { continue; }
        const size = pictures.getLong(1), resource = resources[index];
        if (size <= 0 || size > MAX_PICTURE_BYTES || total + size > MAX_SNAPSHOT_BYTES) { resource.failure = 'size'; continue; }
        const data = new Uint8Array(pictures.getBlob(2)).buffer as ArrayBuffer;
        const mimeType = pictureMimeType(data, pictures.getString(3));
        if (mimeType) { resource.picture = { data, mimeType }; resource.failure = ''; resource.status = 0; total += data.byteLength; }
        else { resource.failure = 'format'; }
      } } finally { pictures.close(); }
    });
    return { attempted, resources };
  }

  async saveSnapshot(accountId: string, messageKey: string, resources: SnapshotPicture[], window: PictureSnapshotWindow): Promise<boolean> {
    if (!this.validKey(accountId, messageKey) || resources.length > MAX_SNAPSHOT_PICTURES ||
      window.owner !== JSON.stringify([accountId, messageKey])) { return false; }
    const manifest = JSON.stringify(resources.map((resource: SnapshotPicture): StoredSnapshotPicture => ({ url: resource.url, failure: resource.failure, status: resource.status })));
    if (manifest.length > 3 * 1024 * 1024) { return false; }
    let saved = false;
    await this.queue(async () => {
      if (!this.snapshotCurrent(window)) { return; }
      this.db.beginTransaction();
      try {
        await this.db.executeSql("INSERT OR REPLACE INTO picture_snapshot (account_id, message_key, manifest) SELECT id, ?, ? FROM accounts WHERE id = ? AND status = 'ready'", [messageKey, manifest, accountId]);
        if (!this.snapshotCurrent(window)) { this.db.rollBack(); return; }
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Picture snapshot could not be saved'); }
      // Read only after committing so pooled readers see the saved marker.
      const rows = await this.db.querySql("SELECT p.manifest FROM picture_snapshot p JOIN accounts a ON a.id = p.account_id WHERE a.status = 'ready' AND p.account_id = ? AND p.message_key = ?", [accountId, messageKey]);
      try { saved = rows.goToFirstRow() && rows.getString(0) === manifest; } finally { rows.close(); }
    });
    return saved;
  }

  private flight(accountId: string, messageKey: string, source: string, refresh: boolean, deadline: number = Number.POSITIVE_INFINITY,
    scope?: PictureSnapshotScope): PictureFlight {
    const owner = JSON.stringify([accountId, messageKey]);
    const generation = this.generations.get(owner) || 0, foregroundRevision = PictureCache.foregroundRevision;
    // Never accept credential-bearing URLs, local files, or other schemes.
    if (!this.validKey(accountId, messageKey) || source.length > 8192 ||
      !/^https?:\/\/[^\s\\\/?#@]+(?:[\/?#]|$)/i.test(source) || /[\u0000-\u0020\u007f\\]/.test(source)) {
      return { task: Promise.resolve(null), result: Promise.resolve(pictureResult(null, 'address')), refresh, generation, foregroundRevision };
    }
    const key = JSON.stringify([accountId, messageKey, source]);
    const existing = this.flights.get(key);
    if (existing && existing.scope === scope && existing.generation === generation && existing.foregroundRevision === foregroundRevision &&
      (!refresh || existing.refresh)) { return existing; }
    // A user refresh waits for an older load before replacing its bytes. A
    // second refresh joins this flight, so old responses cannot win the race.
    const load = (): Promise<PictureLoadResult> => this.loadPicture(accountId, messageKey, source, refresh, owner, generation, foregroundRevision, deadline, scope);
    const result = (existing ? existing.result.then(load) : load()).catch((): PictureLoadResult =>
      pictureResult(null, this.current(owner, generation, foregroundRevision, scope) ? 'storage' : ''));
    const task = result.then((value: PictureLoadResult): CachedPicture | null => value.picture);
    const flight: PictureFlight = { task, result, refresh, generation, foregroundRevision, scope };
    this.flights.set(key, flight);
    result.then(() => { if (this.flights.get(key) === flight) { this.flights.delete(key); } });
    return flight;
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
            const data = new Uint8Array(bytes).buffer as ArrayBuffer;
            const mimeType = pictureMimeType(data, rows.getString(1));
            if (mimeType) { picture = { data, mimeType }; }
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

  private async loadPicture(accountId: string, messageKey: string, source: string, refresh: boolean,
    owner: string, generation: number, foregroundRevision: number, deadline: number, scope?: PictureSnapshotScope): Promise<PictureLoadResult> {
    if (!await this.allowed(accountId, messageKey)) { return pictureResult(null, 'consent'); }
    // An explicit retry may still display freshly downloaded bytes when a
    // transient cache read fails; consent remains mandatory and is rechecked.
    const cached = await this.cached(accountId, messageKey, source).catch((error: Error): null => {
      if (!refresh) { throw error; }
      return null;
    });
    if (cached && !refresh) { return pictureResult(cached); }
    if (!this.current(owner, generation, foregroundRevision, scope)) { return pictureResult(cached); }
    if (Date.now() >= deadline) { return pictureResult(cached, 'network'); }
    await this.acquire();
    try {
      // A hidden reader may leave many images queued behind the four active
      // requests. Finish those active downloads, but start no later sockets.
      if (!this.current(owner, generation, foregroundRevision, scope)) { return pictureResult(cached); }
      if (Date.now() >= deadline) { return pictureResult(cached, 'network'); }
      // The account may have been removed while waiting behind other images.
      if (!await this.allowed(accountId, messageKey)) { return pictureResult(null, 'consent'); }
      if (scope?.permitted && !await scope.permitted().catch(() => false)) {
        // Revocation cancels this job, not the message. Do not persist a failed
        // attempt for images that a future authorized sync has never fetched.
        scope.revoked = true; return pictureResult(cached);
      }
      if (!this.current(owner, generation, foregroundRevision, scope)) { return pictureResult(cached); }
      if (Date.now() >= deadline) { return pictureResult(cached, 'network'); }
      const request = http.createHttp();
      try {
        // Each request is new, so no cookie jar, mailbox authorization, or
        // referring document is shared. The SDK bounds response bytes itself.
        const response = await request.request(source, {
          method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
          usingCache: false, header: { 'Accept': 'image/*' },
          connectTimeout: 10000, readTimeout: 20000, maxLimit: MAX_PICTURE_BYTES
        });
        if (response.responseCode !== 200) {
          const status = Number.isInteger(response.responseCode) && response.responseCode >= 100 && response.responseCode <= 599 ? response.responseCode : 0;
          return pictureResult(cached, 'server', status);
        }
        if (!(response.result instanceof ArrayBuffer) || response.result.byteLength === 0) { return pictureResult(cached, 'format'); }
        if (response.result.byteLength > MAX_PICTURE_BYTES) { return pictureResult(cached, 'size'); }
        const headers = response.header as Record<string, string>;
        const typeKey = Object.keys(headers).find(key => key.toLowerCase() === 'content-type');
        const mimeType = pictureMimeType(response.result, typeKey ? String(headers[typeKey]) : '');
        if (!mimeType) { return pictureResult(cached, 'format'); }
        const picture: CachedPicture = { data: response.result, mimeType };
        // Cache failures must not discard a successful download. A failed
        // transaction preserves the previous offline copy and its timestamp.
        try { await this.save(accountId, messageKey, source, picture); }
        catch (_) { return pictureResult(picture, 'storage'); }
        return pictureResult(picture);
      } catch (error) {
        // Explicit refresh never deletes a usable offline copy or its consent.
        const tooLarge = (error as PictureNetworkError | undefined)?.code === 2300063;
        return pictureResult(cached, tooLarge ? 'size' : 'network');
      } finally { request.destroy(); }
    } finally { this.release(); }
  }

  private save(accountId: string, messageKey: string, source: string, picture: CachedPicture): Promise<void> {
    return this.queue(async () => {
      this.db.beginTransaction();
      try {
        const now = Date.now();
        // Pooled readers cannot see this transaction's pending INSERT/DELETE.
        // Read the committed total and account for replacement bytes explicitly.
        // A normal insertion returns one scalar across the RDB bridge, without
        // sorting/copying the entire account's image inventory into ArkTS.
        const sizes = await this.db.querySql('SELECT COALESCE(SUM(length(data)), 0) FROM picture_cache WHERE account_id = ? AND saved_at > ? AND saved_at <= ? AND NOT (message_key = ? AND url = ?)',
          [accountId, now - MAIL_RETENTION_MS, now, messageKey, source]);
        const stored: StoredPicture[] = []; let total = picture.data.byteLength;
        try { if (sizes.goToFirstRow()) { total += sizes.getLong(0); } } finally { sizes.close(); }
        if (total > ACCOUNT_PICTURE_BYTES) {
          // Read only the oldest victims needed to make room. The expiry index
          // supplies this exact order without a per-download inventory sort.
          const rows = await this.db.querySql('SELECT message_key, url, length(data) FROM picture_cache WHERE account_id = ? AND saved_at > ? AND saved_at <= ? AND NOT (message_key = ? AND url = ?) ORDER BY saved_at ASC, message_key, url',
            [accountId, now - MAIL_RETENTION_MS, now, messageKey, source]);
          try { while (total > ACCOUNT_PICTURE_BYTES && rows.goToNextRow()) {
            const size = rows.getLong(2); total -= size;
            stored.push({ message: rows.getString(0), url: rows.getString(1), size });
          } } finally { rows.close(); }
        }
        await this.db.executeSql('DELETE FROM picture_cache WHERE account_id = ? AND (saved_at <= ? OR saved_at > ?)', [accountId, now - MAIL_RETENTION_MS, now]);
        // The consent and ready-account join also prevents a late HTTP result
        // from resurrecting data after account deletion.
        await this.db.executeSql("INSERT OR REPLACE INTO picture_cache (account_id, message_key, url, mime_type, data, saved_at) SELECT c.account_id, c.message_key, ?, ?, ?, ? FROM picture_consent c JOIN accounts a ON a.id = c.account_id WHERE a.status = 'ready' AND c.account_id = ? AND c.message_key = ?", [source, picture.mimeType, new Uint8Array(picture.data), now, accountId, messageKey]);
        for (const entry of stored) {
          await this.db.executeSql('DELETE FROM picture_cache WHERE account_id = ? AND message_key = ? AND url = ?', [accountId, entry.message, entry.url]);
        }
        this.db.commit();
      } catch (_) { this.db.rollBack(); throw new Error('Picture cache could not be saved'); }
    });
  }

  async whenIdle(): Promise<void> {
    while (this.flights.size > 0 || this.snapshotTasks.size > 0) {
      await Promise.all(Array.from(this.flights.values()).map(flight => flight.task.then(() => {})).concat(Array.from(this.snapshotTasks)));
    }
  }
}
