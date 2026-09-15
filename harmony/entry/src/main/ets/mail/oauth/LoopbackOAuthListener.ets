// MPL-2.0: https://mozilla.org/MPL/2.0/
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

class CallbackConnection {
  connection: socket.TCPSocketConnection;
  bytes: string = '';
  timer: number = -1;
  processing: boolean = false;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}

// A short-lived HTTP callback receiver, bound only to the device's IPv4 loopback.
// Swift still validates state/redirect and claims each authorization code once.
export class LoopbackOAuthListener {
  private server?: socket.TCPSocketServer;
  private clients: Map<number, CallbackConnection> = new Map();
  private uri: string = '';
  private authority: string = '';
  private deadline: number = -1;
  private closing?: Promise<void>;
  private handle: (callback: string) => Promise<boolean>;
  private failed: () => void;
  private completed: () => void;

  constructor(handle: (callback: string) => Promise<boolean>, failed: () => void, completed: () => void = () => {}) {
    this.handle = handle; this.failed = failed; this.completed = completed;
  }

  async open(lifetimeMs: number = 600000, port: number = 0): Promise<string> {
    if (this.server || this.closing || lifetimeMs < 1 || lifetimeMs > 600000 ||
      !Number.isInteger(port) || port < 0 || port > 65535) { throw new Error('Invalid listener lifecycle'); }
    const server = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('connect', (connection) => this.accept(connection));
    server.on('error', () => { this.failed(); this.close().catch(() => {}); });
    try {
      await server.listen({ address: '127.0.0.1', family: 1, port: port });
      const address = await server.getLocalAddress();
      if (address.address !== '127.0.0.1' || !address.port || address.port < 1 || address.port > 65535 ||
        (port !== 0 && address.port !== port)) {
        throw new Error('Invalid loopback address');
      }
      this.authority = `127.0.0.1:${address.port}`;
      this.uri = `http://${this.authority}/oauth2redirect`;
      this.deadline = setTimeout(() => { this.failed(); this.close().catch(() => {}); }, lifetimeMs);
      return this.uri;
    } catch (_) { await this.close(); throw new Error('Loopback listener unavailable'); }
  }

  private accept(connection: socket.TCPSocketConnection): void {
    if (this.closing || this.uri === '' || this.clients.size >= 4) { connection.close().catch(() => {}); return; }
    const client = new CallbackConnection(connection);
    this.clients.set(connection.clientId, client);
    client.timer = setTimeout(() => { this.drop(client); }, 3000);
    connection.on('close', () => { this.drop(client); });
    connection.on('error', () => { this.drop(client); });
    connection.on('message', (info: socket.SocketMessageInfo) => { this.receive(client, info.message); });
  }

  private drop(client: CallbackConnection): void {
    if (!this.clients.delete(client.connection.clientId)) { return; }
    clearTimeout(client.timer);
    client.bytes = '';
    client.connection.off('message'); client.connection.off('close'); client.connection.off('error');
    client.connection.close().catch(() => {});
  }

  private receive(client: CallbackConnection, message: ArrayBuffer): void {
    if (client.processing || message.byteLength + client.bytes.length > 49152) { this.drop(client); return; }
    const bytes = new Uint8Array(message);
    for (let i = 0; i < bytes.length; i++) {
      if (bytes[i] > 126 || (bytes[i] < 32 && bytes[i] !== 9 && bytes[i] !== 10 && bytes[i] !== 13)) {
        this.drop(client); return;
      }
    }
    client.bytes += new util.TextDecoder().decodeToString(bytes);
    const end = client.bytes.indexOf('\r\n\r\n');
    if (end < 0) { return; }
    client.processing = true;
    clearTimeout(client.timer);
    client.timer = setTimeout(() => { this.drop(client); }, 20000);
    const lines = client.bytes.substring(0, end).split('\r\n');
    const start = lines.shift()?.match(/^GET (\/oauth2redirect\?[^\s#]+) HTTP\/1\.[01]$/);
    const headers: Map<string, string> = new Map();
    let valid = end + 4 === client.bytes.length && start !== null && start !== undefined;
    for (const line of lines) {
      const field = line.match(/^([A-Za-z0-9-]+):[ \t]*([^\r\n]*)$/);
      if (!field || headers.has(field[1].toLowerCase())) { valid = false; break; }
      headers.set(field[1].toLowerCase(), field[2].trim());
    }
    valid = valid && headers.get('host') === this.authority && !headers.has('origin') &&
      !headers.has('transfer-encoding') && (!headers.has('content-length') || headers.get('content-length') === '0');
    const callback = valid && start ? `http://${this.authority}${start[1]}` : '';
    client.bytes = '';
    this.respond(client, callback).catch(() => { this.drop(client); });
  }

  private async respond(client: CallbackConnection, callback: string): Promise<void> {
    let accepted = false;
    if (callback !== '' && !this.closing) { accepted = await this.handle(callback); }
    const body = accepted ? 'You can close this browser tab and return to D-Mail.' : 'This sign-in callback was not accepted.';
    // Never echo the URL, authorization code, state or provider error into HTML.
    const response = `HTTP/1.1 ${accepted ? '200 OK' : '400 Bad Request'}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.length}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n${body}`;
    try { await client.connection.send({ data: response }); }
    finally {
      this.drop(client);
      if (accepted) { try { await this.close(); } finally { this.completed(); } }
    }
  }

  close(): Promise<void> {
    if (!this.closing) { this.closing = this.stop(); }
    return this.closing;
  }

  private async stop(): Promise<void> {
    clearTimeout(this.deadline);
    this.uri = '';
    const clients = Array.from(this.clients.values());
    for (const client of clients) { this.drop(client); }
    const server = this.server;
    this.server = undefined;
    if (server) { server.off('connect'); server.off('error'); await server.close(); }
  }
}
