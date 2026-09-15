// Isolated synthetic performance fixture: encrypted cache and loopback HTTP only.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PictureCache } from '../data/PictureCache';
import { HtmlScrollPowerState } from './HtmlScrollPowerState';

class PictureScrollConnection {
  connection: socket.TCPSocketConnection;
  bytes: string = '';
  ready: boolean = false;
  timer: number = -1;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}

export class HtmlPictureScrollState {
  static cache?: PictureCache;
  static url: string = '';
  static resourceCallbacks: number = 0;
  static cacheCallbacks: number = 0;
  static goodRequests: number = 0;
  static missingRequests: number = 0;
  static trackerRequests: number = 0;
  static closeTapMs: number = 0;
  static closeVisibleMs: number = 0;
  private static db?: relationalStore.RdbStore;
  private static server?: socket.TCPSocketServer;
  private static clients: Map<number, PictureScrollConnection> = new Map();
  private static images: Map<string, Uint8Array> = new Map();
  private static savedAt: Map<string, number> = new Map();
  private static sealed: boolean = false;
  private static deadline: number = -1;
  private static readonly missing: string[] = ['/missing-a.png', '/missing-b.png'];
  private static readonly trackers: string[] = ['/tracker-a.png', '/tracker-b.png'];

  static async open(context: common.UIAbilityContext): Promise<void> {
    await HtmlPictureScrollState.close();
    HtmlPictureScrollState.resourceCallbacks = 0; HtmlPictureScrollState.cacheCallbacks = 0;
    HtmlPictureScrollState.goodRequests = 0; HtmlPictureScrollState.missingRequests = 0;
    HtmlPictureScrollState.trackerRequests = 0; HtmlPictureScrollState.sealed = false;
    HtmlPictureScrollState.closeTapMs = 0; HtmlPictureScrollState.closeVisibleMs = 0;
    HtmlPictureScrollState.images.clear(); HtmlPictureScrollState.savedAt.clear();
    const server = socket.constructTCPSocketServerInstance();
    HtmlPictureScrollState.server = server;
    server.on('connect', connection => HtmlPictureScrollState.accept(connection));
    server.on('error', () => { HtmlPictureScrollState.stopServer().catch(() => {}); });
    try {
      await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
      const address = await server.getLocalAddress();
      if (address.address !== '127.0.0.1' || !address.port) { throw new Error('Fixture must bind loopback'); }
      HtmlPictureScrollState.url = `http://127.0.0.1:${address.port}`;
      HtmlPictureScrollState.deadline = setTimeout(() => {
        HtmlPictureScrollState.close().catch(() => {});
      }, 180000);
      for (let index = 0; index < 20; index++) {
        const bytes = await context.resourceManager.getRawFileContent(`picture-scroll/picture-${index}.png`);
        if (bytes.length < 100 || bytes.length > 1024 * 1024) { throw new Error('Synthetic PNG size exceeded budget'); }
        HtmlPictureScrollState.images.set(`/picture-${index}.png`, bytes);
      }
      const db = await relationalStore.getRdbStore(context, {
        name: 'picture_scroll_fixture.db', securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
      });
      HtmlPictureScrollState.db = db;
      await db.executeSql('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL)');
      await PictureCache.initialize(db);
      await db.executeSql('DELETE FROM picture_cache'); await db.executeSql('DELETE FROM picture_consent');
      await db.executeSql("INSERT OR REPLACE INTO accounts (id, status) VALUES ('synthetic-scroll', 'ready')");
      let tail: Promise<void> = Promise.resolve();
      const cache = new PictureCache(db, operation => {
        const current = tail.then(operation); tail = current.catch(() => {}); return current;
      });
      HtmlPictureScrollState.cache = cache;
      await cache.allow('synthetic-scroll', 'synthetic-picture-message');
      // Real transport, format validation and persistence complete before any
      // measured phase. The normal cache limits concurrency to four requests.
      const downloads: Promise<void>[] = [];
      for (const path of HtmlPictureScrollState.images.keys()) {
        downloads.push(cache.loadWithStatus('synthetic-scroll', 'synthetic-picture-message', HtmlPictureScrollState.url + path)
          .then(result => { if (!result.picture || result.failure) { throw new Error('Synthetic cache priming failed'); } }));
      }
      await Promise.all(downloads); await cache.whenIdle();
      if (HtmlPictureScrollState.goodRequests !== 20 || !await HtmlPictureScrollState.cacheIntact()) {
        throw new Error('Synthetic cache priming count or bytes mismatch');
      }
      // A sentinel stays available and counts any mistaken good-image refetch.
      HtmlPictureScrollState.sealed = true;
    } catch (error) { await HtmlPictureScrollState.close(); throw error as Error; }
  }

  static record(scene: number, stage: string, url: string): void {
    if (!HtmlScrollPowerState.owns(HtmlScrollPowerState.mode, scene) ||
      !url.startsWith(HtmlPictureScrollState.url + '/') || !HtmlPictureScrollState.url) { return; }
    if (stage === 'resource') { ++HtmlPictureScrollState.resourceCallbacks; }
    else if (stage === 'cache') { ++HtmlPictureScrollState.cacheCallbacks; }
  }
  static counts(): string {
    return `resources=${HtmlPictureScrollState.resourceCallbacks},cache=${HtmlPictureScrollState.cacheCallbacks},` +
      `good_http=${HtmlPictureScrollState.goodRequests},missing_http=${HtmlPictureScrollState.missingRequests},` +
      `tracker_http=${HtmlPictureScrollState.trackerRequests}`;
  }
  static async idle(): Promise<void> { await HtmlPictureScrollState.cache?.whenIdle(); }
  static recordCloseTap(scene: number): void {
    if (scene === HtmlScrollPowerState.scene) { HtmlPictureScrollState.closeTapMs = Date.now(); }
  }
  static recordCloseVisible(scene: number): void {
    if (scene === HtmlScrollPowerState.scene) { HtmlPictureScrollState.closeVisibleMs = Date.now(); }
  }

  static document(): string {
    let html = '<h2>Synthetic picture scroll email</h2><p>20 saved 800 × 450 pictures, 1500 rows, two unavailable visible pictures.</p>' +
      `<p><img src="${HtmlPictureScrollState.url}/missing-a.png" width="300" height="80" alt="Synthetic missing A"></p>` +
      `<p><img src="${HtmlPictureScrollState.url}/missing-b.png" width="300" height="80" alt="Synthetic missing B"></p>`;
    const sections: string[] = [];
    for (let index = 0; index < 20; index++) {
      const rows: string[] = [];
      for (let row = 0; row < 75; row++) {
        const number = index * 75 + row + 1;
        rows.push(`<tr><td>Row ${number}</td><td>Synthetic picture newsletter 東京 — paragraph ${number}. ` +
          'This generated message uses only isolated loopback images and contains no account data.</td></tr>');
      }
      sections.push(`<p><img src="${HtmlPictureScrollState.url}/picture-${index}.png" width="800" height="450" ` +
        `alt="Synthetic static picture ${index + 1}"></p><table><tbody>${rows.join('')}</tbody></table>`);
    }
    html += sections.join('') + `<img src="${HtmlPictureScrollState.url}/tracker-a.png" width="1" height="1">` +
      `<img src="${HtmlPictureScrollState.url}/tracker-b.png" width="1" height="1"><p>End of synthetic picture email</p>`;
    if (html.length * 3 > 1024 * 1024) { throw new Error('Synthetic HTML exceeds 1MB byte budget'); }
    HtmlScrollPowerState.htmlLength = html.length;
    return html;
  }

  private static accept(connection: socket.TCPSocketConnection): void {
    if (HtmlPictureScrollState.clients.size >= 4 || !HtmlPictureScrollState.url) { connection.close().catch(() => {}); return; }
    const client = new PictureScrollConnection(connection);
    HtmlPictureScrollState.clients.set(connection.clientId, client);
    client.timer = setTimeout(() => HtmlPictureScrollState.drop(client), 15000);
    connection.on('close', () => HtmlPictureScrollState.drop(client));
    connection.on('error', () => HtmlPictureScrollState.drop(client));
    connection.on('message', info => {
      if (client.ready || client.bytes.length + info.message.byteLength > 8192) { HtmlPictureScrollState.drop(client); return; }
      client.bytes += new util.TextDecoder().decodeToString(new Uint8Array(info.message));
      if (!client.bytes.includes('\r\n\r\n')) { return; }
      const match = /^GET (\/[-a-z0-9]+\.png) HTTP\/1\.[01]\r\n/.exec(client.bytes);
      const path = match ? match[1] : '';
      const host = HtmlPictureScrollState.url.split('/')[2];
      if (!client.bytes.toLowerCase().includes(`\r\nhost: ${host}\r\n`) ||
        (!HtmlPictureScrollState.images.has(path) && !HtmlPictureScrollState.missing.includes(path) &&
        !HtmlPictureScrollState.trackers.includes(path))) { HtmlPictureScrollState.drop(client); return; }
      client.ready = true;
      if (HtmlPictureScrollState.images.has(path)) { ++HtmlPictureScrollState.goodRequests; }
      else if (HtmlPictureScrollState.missing.includes(path)) { ++HtmlPictureScrollState.missingRequests; }
      else { ++HtmlPictureScrollState.trackerRequests; }
      const success = HtmlPictureScrollState.images.has(path) && !HtmlPictureScrollState.sealed;
      const body = success ? HtmlPictureScrollState.images.get(path)! : new Uint8Array();
      const header = new util.TextEncoder().encodeInto(`HTTP/1.1 ${success ? '200 OK' : '503 Service Unavailable'}\r\n` +
        `Content-Type: ${success ? 'image/png' : 'text/plain'}\r\nContent-Length: ${body.byteLength}\r\n` +
        'Cache-Control: no-store\r\nConnection: close\r\n\r\n');
      const response = new Uint8Array(header.byteLength + body.byteLength);
      response.set(header); response.set(body, header.byteLength);
      client.connection.send({ data: response.buffer as ArrayBuffer }).catch(() => {})
        .then(() => HtmlPictureScrollState.drop(client));
    });
  }

  private static drop(client: PictureScrollConnection): void {
    if (!HtmlPictureScrollState.clients.delete(client.connection.clientId)) { return; }
    clearTimeout(client.timer);
    client.connection.off('message'); client.connection.off('close'); client.connection.off('error');
    client.connection.close().catch(() => {});
  }
  static async cacheIntact(): Promise<boolean> {
    if (!HtmlPictureScrollState.db) { return false; }
    const rows = await HtmlPictureScrollState.db.querySql(
      'SELECT data, saved_at, mime_type, url FROM picture_cache WHERE account_id = ? AND message_key = ?',
      ['synthetic-scroll', 'synthetic-picture-message']);
    try {
      let count = 0;
      while (rows.goToNextRow()) {
        const url = rows.getString(3), path = url.slice(HtmlPictureScrollState.url.length);
        const expected = HtmlPictureScrollState.images.get(path);
        if (!url.startsWith(HtmlPictureScrollState.url + '/') || !expected || rows.getString(2) !== 'image/png') { return false; }
        const bytes = rows.getBlob(0), savedAt = rows.getLong(1);
        if (bytes.length !== expected.length || !bytes.every((value, index) => value === expected[index])) { return false; }
        if (!HtmlPictureScrollState.savedAt.has(path)) { HtmlPictureScrollState.savedAt.set(path, savedAt); }
        if (savedAt <= 0 || savedAt !== HtmlPictureScrollState.savedAt.get(path)) { return false; }
        ++count;
      }
      return count === 20;
    } finally { rows.close(); }
  }
  private static async stopServer(): Promise<void> {
    clearTimeout(HtmlPictureScrollState.deadline);
    for (const client of Array.from(HtmlPictureScrollState.clients.values())) { HtmlPictureScrollState.drop(client); }
    const server = HtmlPictureScrollState.server; HtmlPictureScrollState.server = undefined;
    if (server) { server.off('connect'); server.off('error'); await server.close(); }
  }
  static async close(): Promise<void> {
    HtmlPictureScrollState.cache?.cancelPending('synthetic-scroll', 'synthetic-picture-message');
    await HtmlPictureScrollState.stopServer();
    const cache = HtmlPictureScrollState.cache; HtmlPictureScrollState.cache = undefined;
    if (cache) { await cache.whenIdle(); }
    const db = HtmlPictureScrollState.db; HtmlPictureScrollState.db = undefined;
    if (db) { await db.close(); }
    HtmlPictureScrollState.url = '';
  }
}
