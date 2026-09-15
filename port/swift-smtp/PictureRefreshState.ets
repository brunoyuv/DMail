// Synthetic-only main-HAP fixture. All HTTP is bound to device loopback.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PictureCache } from '../data/PictureCache';
import { PictureRefreshTrace } from './PictureRefreshTrace';

class PictureConnection {
  connection: socket.TCPSocketConnection;
  bytes: string = '';
  ready: boolean = false;
  responding: boolean = false;
  path: string = '';
  timer: number = -1;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}

export class PictureRefreshState {
  static cache?: PictureCache;
  static url: string = '';
  static requests: number = 0;
  static nonContentRequests: number = 0;
  private static db?: relationalStore.RdbStore;
  private static server?: socket.TCPSocketServer;
  private static clients: Map<number, PictureConnection> = new Map();
  private static held: boolean = false;
  private static missingReady: boolean = false;
  private static unavailable: boolean = false;
  private static deadline: number = -1;
  private static counts: Map<string, number> = new Map();
  private static savedAt: Map<string, number> = new Map();
  private static readonly paths: string[] = ['/good.png', '/connection.png', '/server.png'];
  private static readonly nonContentPaths: string[] = ['/tracking.gif', '/hidden.png'];
  private static png: Uint8Array = new Uint8Array();
  private static replacement: Uint8Array = new Uint8Array();

  static async open(context: common.UIAbilityContext): Promise<void> {
    await PictureRefreshState.close();
    PictureRefreshTrace.reset();
    PictureRefreshState.requests = 0; PictureRefreshState.nonContentRequests = 0; PictureRefreshState.held = false;
    PictureRefreshState.missingReady = false; PictureRefreshState.unavailable = false;
    PictureRefreshState.counts.clear(); PictureRefreshState.savedAt.clear();
    const server = socket.constructTCPSocketServerInstance();
    PictureRefreshState.server = server;
    server.on('connect', connection => PictureRefreshState.accept(connection));
    server.on('error', () => { PictureRefreshTrace.record('server_error'); PictureRefreshState.release(); });
    try {
      await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
      const address = await server.getLocalAddress();
      if (address.address !== '127.0.0.1' || !address.port) { throw new Error('Fixture must bind loopback'); }
      PictureRefreshState.url = `http://127.0.0.1:${address.port}`;
      PictureRefreshState.deadline = setTimeout(() => { PictureRefreshState.release(); PictureRefreshState.stopServer().catch(() => {}); }, 45000);
      const db = await relationalStore.getRdbStore(context, {
        name: 'picture_refresh_fixture.db', securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
      });
      PictureRefreshState.db = db;
      await db.executeSql('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL)');
      await PictureCache.initialize(db);
      await db.executeSql('DELETE FROM picture_cache');
      await db.executeSql('DELETE FROM picture_consent');
      await db.executeSql("INSERT OR REPLACE INTO accounts (id, status) VALUES ('synthetic-pictures', 'ready')");
      let tail: Promise<void> = Promise.resolve();
      PictureRefreshState.cache = new PictureCache(db, operation => {
        const current = tail.then(operation); tail = current.catch(() => {}); return current;
      });
      await PictureRefreshState.cache.allow('synthetic-pictures', 'synthetic-message');
      PictureRefreshState.png = await context.resourceManager.getRawFileContent('picture-refresh.png');
      PictureRefreshState.replacement = await context.resourceManager.getRawFileContent('picture-refresh-replacement.png');
      // Intentionally no INSERT: the first PNG arrives as octet-stream and must pass real HTTP200,
      // ArrayBuffer/MIME handling and persistence before ArkWeb can display it.
    } catch (error) { await PictureRefreshState.close(); throw error as Error; }
  }

  static trace(): string { return PictureRefreshTrace.read(); }
  static requestCounts(): string {
    return PictureRefreshState.paths.map(path => PictureRefreshState.counts.get(path) || 0).join(',');
  }

  private static accept(connection: socket.TCPSocketConnection): void {
    PictureRefreshTrace.record('http_connection');
    if (PictureRefreshState.clients.size >= 4 || !PictureRefreshState.url) { connection.close().catch(() => {}); return; }
    const client = new PictureConnection(connection);
    PictureRefreshState.clients.set(connection.clientId, client);
    client.timer = setTimeout(() => PictureRefreshState.drop(client), 15000);
    connection.on('close', () => PictureRefreshState.drop(client));
    connection.on('error', () => { PictureRefreshTrace.record('http_error'); PictureRefreshState.drop(client); });
    connection.on('message', info => {
      if (client.ready || client.bytes.length + info.message.byteLength > 8192) { PictureRefreshState.drop(client); return; }
      client.bytes += new util.TextDecoder().decodeToString(new Uint8Array(info.message));
      if (!client.bytes.includes('\r\n\r\n')) { return; }
      const authority = PictureRefreshState.url.split('/')[2];
      const path = PictureRefreshState.paths.concat(PictureRefreshState.nonContentPaths)
        .find(value => client.bytes.startsWith(`GET ${value} HTTP/1.`));
      const requestLineValid = path !== undefined;
      const hostValid = client.bytes.toLowerCase().includes(`\r\nhost: ${authority}\r\n`);
      PictureRefreshTrace.record(requestLineValid ? 'request_line_valid' : 'request_line_invalid');
      PictureRefreshTrace.record(hostValid ? 'host_valid' : 'host_invalid');
      if (!path || !hostValid) { PictureRefreshState.drop(client); return; }
      client.path = path;
      client.ready = true; PictureRefreshState.requests++;
      if (PictureRefreshState.nonContentPaths.includes(path)) { PictureRefreshState.nonContentRequests++; }
      PictureRefreshState.counts.set(path, (PictureRefreshState.counts.get(path) || 0) + 1);
      if (!PictureRefreshState.held) { PictureRefreshState.respond(client); }
    });
  }

  private static drop(client: PictureConnection): void {
    if (!PictureRefreshState.clients.delete(client.connection.clientId)) { return; }
    clearTimeout(client.timer);
    client.connection.off('message'); client.connection.off('close'); client.connection.off('error');
    client.connection.close().catch(() => {});
  }

  private static respond(client: PictureConnection): void {
    if (client.responding) { return; }
    client.responding = true;
    const missing = client.path !== '/good.png' && !PictureRefreshState.missingReady;
    if (missing && client.path === '/connection.png' && !PictureRefreshState.unavailable) {
      PictureRefreshTrace.record('http_connection_failed'); PictureRefreshState.drop(client); return;
    }
    // These two invisible references never recover. Filtering must prevent
    // their requests and warnings, including on explicit retry and remount.
    const failed = PictureRefreshState.unavailable || missing || PictureRefreshState.nonContentPaths.includes(client.path);
    PictureRefreshTrace.record(failed ? 'http_503' : 'http_200');
    const body = failed ? new Uint8Array() :
      (client.path === '/good.png' ? PictureRefreshState.png : PictureRefreshState.replacement);
    const header = new util.TextEncoder().encodeInto(`HTTP/1.1 ${failed ? '503 Service Unavailable' : '200 OK'}\r\nContent-Type: ${failed ? 'text/plain' : 'application/octet-stream'}\r\nContent-Length: ${body.byteLength}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`);
    const response = new Uint8Array(header.byteLength + body.byteLength);
    response.set(header); response.set(body, header.byteLength);
    client.connection.send({ data: response.buffer as ArrayBuffer })
      .catch(() => { PictureRefreshTrace.record('http_send_failed'); }).then(() => PictureRefreshState.drop(client));
  }

  static holdFailures(): void { PictureRefreshState.held = true; }
  static recoverMissing(): void { PictureRefreshState.missingReady = true; }
  // Keep a loopback sentinel listening so even an attempted cached-image
  // re-download is counted. Every resource is now unavailable (HTTP503).
  static makeUnavailable(): void { PictureRefreshState.unavailable = true; }

  static release(): void {
    PictureRefreshState.held = false;
    for (const client of PictureRefreshState.clients.values()) { if (client.ready) { PictureRefreshState.respond(client); } }
  }

  static async cacheIntact(expectedCount: number): Promise<boolean> {
    if (!PictureRefreshState.db) { return false; }
    const rows = await PictureRefreshState.db.querySql('SELECT data, saved_at, mime_type, url FROM picture_cache WHERE account_id = ? AND message_key = ?',
      ['synthetic-pictures', 'synthetic-message']);
    try {
      let count = 0;
      while (rows.goToNextRow()) {
        const url = rows.getString(3), path = url.slice(PictureRefreshState.url.length);
        if (!url.startsWith(PictureRefreshState.url) || !PictureRefreshState.paths.includes(path) ||
          (expectedCount === 1 && path !== '/good.png') || rows.getString(2) !== 'image/png') { return false; }
        const expected = path === '/good.png' ? PictureRefreshState.png : PictureRefreshState.replacement;
        const actual = rows.getBlob(0), savedAt = rows.getLong(1);
        if (actual.length !== expected.length || !actual.every((value, index) => value === expected[index])) { return false; }
        if (!PictureRefreshState.savedAt.has(path)) { PictureRefreshState.savedAt.set(path, savedAt); }
        if (savedAt <= 0 || savedAt !== PictureRefreshState.savedAt.get(path)) { return false; }
        count++;
      }
      return count === expectedCount;
    } finally { rows.close(); }
  }

  private static async stopServer(): Promise<void> {
    clearTimeout(PictureRefreshState.deadline);
    for (const client of Array.from(PictureRefreshState.clients.values())) { PictureRefreshState.drop(client); }
    const server = PictureRefreshState.server; PictureRefreshState.server = undefined;
    if (server) { server.off('connect'); server.off('error'); await server.close(); }
  }

  static async close(): Promise<void> {
    PictureRefreshState.release(); await PictureRefreshState.stopServer();
    const cache = PictureRefreshState.cache; PictureRefreshState.cache = undefined;
    if (cache) { await cache.whenIdle(); }
    const db = PictureRefreshState.db; PictureRefreshState.db = undefined;
    if (db) { await db.close(); }
    PictureRefreshState.url = '';
  }
}
