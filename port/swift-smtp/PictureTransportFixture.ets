// Synthetic-only transport fixture; no external URLs or mail accounts.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PictureCache, CachedPicture } from '../data/PictureCache';

interface TransportImage { bytes: Uint8Array; mime: string; }
export interface TransportSaved { bytes: Uint8Array; mime: string; savedAt: number; }
class TransportConnection {
  connection: socket.TCPSocketConnection;
  request: string = '';
  replied: boolean = false;
  timer: number = -1;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}

export class PictureTransportFixture {
  requests: string[] = [];
  invalid: boolean = false;
  private origin: string = '';
  private db?: relationalStore.RdbStore;
  private cache?: PictureCache;
  private server?: socket.TCPSocketServer;
  private images: Map<string, TransportImage> = new Map();
  private clients: Map<number, TransportConnection> = new Map();
  private deadline: number = -1;

  async open(context: common.UIAbilityContext): Promise<void> {
    this.requests = []; this.invalid = false;
    const db = await relationalStore.getRdbStore(context, {
      name: 'picture_transport_fixture.db', securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
    });
    this.db = db;
    await db.executeSql('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL)');
    await PictureCache.initialize(db);
    await db.executeSql('DELETE FROM picture_cache'); await db.executeSql('DELETE FROM picture_consent');
    await db.executeSql("INSERT OR REPLACE INTO accounts (id, status) VALUES ('synthetic-transport', 'ready')");
    let tail: Promise<void> = Promise.resolve();
    this.cache = new PictureCache(db, operation => {
      const task = tail.then(operation); tail = task.catch(() => {}); return task;
    });
    await this.cache.allow('synthetic-transport', 'message');
    const extensions: string[] = ['png', 'jpeg', 'gif', 'webp'];
    for (const extension of extensions) {
      const bytes = await context.resourceManager.getRawFileContent(`picture-transport.${extension}`);
      this.images.set(`/${extension}`, { bytes, mime: `image/${extension}` });
    }
    const server = socket.constructTCPSocketServerInstance(); this.server = server;
    server.on('connect', connection => this.accept(connection));
    server.on('error', () => { this.stopServer().catch(() => {}); });
    await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
    const address = await server.getLocalAddress();
    if (address.address !== '127.0.0.1' || !address.port) { throw new Error('Fixture must use loopback'); }
    this.origin = `http://127.0.0.1:${address.port}`;
    this.deadline = setTimeout(() => { this.stopServer().catch(() => {}); }, 45000);
  }

  expected(extension: string): Uint8Array { return this.images.get(`/${extension}`)!.bytes; }
  load(route: string, refresh: boolean = false): Promise<CachedPicture | null> {
    if (!this.cache) { throw new Error('Fixture not ready'); }
    return this.cache.load('synthetic-transport', 'message', `${this.origin}${route}`, refresh);
  }
  async saved(route: string): Promise<TransportSaved | null> {
    if (!this.db) { throw new Error('Fixture not ready'); }
    const rows = await this.db.querySql('SELECT data, mime_type, saved_at FROM picture_cache WHERE account_id = ? AND message_key = ? AND url = ?',
      ['synthetic-transport', 'message', `${this.origin}${route}`]);
    try {
      if (!rows.goToFirstRow()) { return null; }
      return { bytes: new Uint8Array(rows.getBlob(0)), mime: rows.getString(1), savedAt: rows.getLong(2) };
    } finally { rows.close(); }
  }

  private accept(connection: socket.TCPSocketConnection): void {
    if (this.clients.size >= 4 || this.origin === '') { connection.close().catch(() => {}); return; }
    const client = new TransportConnection(connection); this.clients.set(connection.clientId, client);
    client.timer = setTimeout(() => this.drop(client), 5000);
    connection.on('close', () => this.drop(client)); connection.on('error', () => this.drop(client));
    connection.on('message', info => {
      if (client.replied || client.request.length + info.message.byteLength > 8192) { this.drop(client); return; }
      client.request += new util.TextDecoder().decodeToString(new Uint8Array(info.message));
      if (!client.request.includes('\r\n\r\n')) { return; }
      const route = /^GET (\/[a-z-]+) HTTP\/1\.[01]\r\n/.exec(client.request)?.[1] ?? '';
      if (!route || !client.request.toLowerCase().includes(`\r\nhost: ${this.origin.split('/')[2]}\r\n`)) { this.drop(client); return; }
      client.replied = true; this.requests.push(route); this.respond(client, route);
    });
  }

  private respond(client: TransportConnection, route: string): void {
    let status: string = '200 OK', extra: string = '', mime: string = 'image/png', headerName: string = 'content-type';
    let bytes: Uint8Array = new Uint8Array();
    if (route === '/redirect-lower' || route === '/redirect-upper') {
      status = '302 Found'; mime = 'text/html';
      const upper = route === '/redirect-upper';
      headerName = upper ? 'content-type' : 'Content-Type';
      extra = `Location: ${this.origin}${upper ? '/png-upper' : '/png'}\r\n`;
    } else if (route === '/mislabeled') {
      mime = 'image/jpeg'; bytes = this.expected('png');
    } else if (route === '/plain') {
      mime = 'text/plain'; bytes = this.expected('png');
    } else if (route === '/png-upper') {
      headerName = 'Content-Type'; bytes = this.expected('png');
    } else {
      const image = this.images.get(route);
      if (!image) { status = '404 Not Found'; mime = 'text/plain'; }
      else {
        mime = image.mime; bytes = image.bytes;
        if (route === '/png' && this.invalid) { bytes = new util.TextEncoder().encodeInto('<html>Synthetic server failure</html>'); }
      }
    }
    const header = new util.TextEncoder().encodeInto(`HTTP/1.1 ${status}\r\n${headerName}: ${mime}\r\nContent-Length: ${bytes.byteLength}\r\n${extra}Cache-Control: no-store\r\nConnection: close\r\n\r\n`);
    const response = new Uint8Array(header.byteLength + bytes.byteLength); response.set(header); response.set(bytes, header.byteLength);
    client.connection.send({ data: response.buffer as ArrayBuffer }).catch(() => {}).then(() => this.drop(client));
  }

  private drop(client: TransportConnection): void {
    if (!this.clients.delete(client.connection.clientId)) { return; }
    clearTimeout(client.timer); client.connection.off('message'); client.connection.off('close'); client.connection.off('error');
    client.connection.close().catch(() => {});
  }
  private async stopServer(): Promise<void> {
    clearTimeout(this.deadline);
    for (const client of Array.from(this.clients.values())) { this.drop(client); }
    const server = this.server; this.server = undefined;
    if (server) { server.off('connect'); server.off('error'); await server.close(); }
  }
  async close(trace: (stage: string) => Promise<void>): Promise<void> {
    try {
      await trace('server_close_start');
      await this.stopServer();
      await trace('server_close_done');
    } finally {
      try {
        await trace('cache_idle_start');
        const cache = this.cache; this.cache = undefined; if (cache) { await cache.whenIdle(); }
        await trace('cache_idle_done');
      } finally {
        await trace('database_close_start');
        const db = this.db; this.db = undefined; if (db) { await db.close(); }
        this.origin = '';
        await trace('database_close_done');
      }
    }
  }
}
