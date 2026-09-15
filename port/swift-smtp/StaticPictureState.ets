// Synthetic-only main-HAP fixture. All HTTP is bound to device loopback.
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { PictureCache } from '../data/PictureCache';
import { StaticPictureTrace } from './StaticPictureTrace';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { PreparedMailDocument } from '../data/PreparedDocumentModel';
import { stableMessageKey } from '../mail/Conversation';
import { MailBodySync } from '../mail/MailBodySync';
import { JmapService, JmapEmail, JmapSession, JmapMailbox, JmapEmailPage, JmapDraft, JmapCreatedDraft,
  JmapKeyword, JmapArchiveUndo } from '../mail/jmap/JmapClient';

class StaticPictureConnection {
  connection: socket.TCPSocketConnection;
  bytes: string = '';
  ready: boolean = false;
  responding: boolean = false;
  path: string = '';
  timer: number = -1;
  constructor(connection: socket.TCPSocketConnection) { this.connection = connection; }
}

class StaticPictureClient implements JmapService {
  async connect(): Promise<JmapSession> { throw new Error('Unexpected synthetic connect'); }
  async mailboxes(_accountId: string): Promise<JmapMailbox[]> { throw new Error('Unexpected synthetic mailbox request'); }
  async emailPage(accountId: string, mailboxId: string, position?: number, queryState?: string): Promise<JmapEmailPage> {
    return StaticPictureState.page(accountId, mailboxId, position, queryState);
  }
  async readEmail(_accountId: string, emailId: string): Promise<JmapEmail | null> {
    return StaticPictureState.readBody(emailId);
  }
  async createDraft(_accountId: string, _draft: JmapDraft): Promise<JmapCreatedDraft> { throw new Error('Unexpected synthetic draft'); }
  async setKeyword(_accountId: string, _emailId: string, _keyword: JmapKeyword, _enabled: boolean): Promise<string> {
    throw new Error('Unexpected synthetic flag request');
  }
  async archiveEmail(_accountId: string, _emailId: string): Promise<JmapArchiveUndo> { throw new Error('Unexpected synthetic move'); }
  async undoArchive(_undo: JmapArchiveUndo): Promise<void> { throw new Error('Unexpected synthetic undo'); }
}

export class StaticPictureState {
  static cache?: PictureCache;
  static savedDocument?: PreparedMailDocument;
  static savedBody: string = '';
  static accountId: string = '';
  static messageKey: string = '';
  private static readonly dbName: string = 'static_picture_fixture.db';
  private static readonly emailId: string = 'synthetic-static-message';
  private static context?: common.UIAbilityContext;
  private static account?: SavedAccount;
  private static store?: AccountStore;
  private static worker?: MailBodySync;
  private static fixtureOpen: boolean = false;
  private static syncAllowed: boolean = true;
  private static checkpointTaken: boolean = false;
  private static checkpointBodies: number = 0;
  private static sealed: boolean = false;
  private static bodyRequests: number = 0;
  private static pageRequests: number[] = [];
  private static bodyIds: Set<string> = new Set();
  private static expectedBodies: Map<string, string> = new Map();
  private static expectedDocuments: Map<string, string> = new Map();
  private static readonly emailIds: string[] = ['synthetic-static-message', 'synthetic-2', 'synthetic-3',
    'synthetic-4', 'synthetic-5', 'synthetic-6', 'synthetic-7'];
  private static readonly pageState: string = 'synthetic-stable-mailbox-state';
  private static expectedDocument: string = '';
  private static expectedBody: string = '';
  static url: string = '';
  static requests: number = 0;
  static nonContentRequests: number = 0;
  private static db?: relationalStore.RdbStore;
  private static server?: socket.TCPSocketServer;
  private static clients: Map<number, StaticPictureConnection> = new Map();
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
    await StaticPictureState.close();
    StaticPictureState.resetScene(); StaticPictureState.context = context;
    StaticPictureState.fixtureOpen = true; StaticPictureState.sealed = false; StaticPictureState.syncAllowed = true;
    StaticPictureState.checkpointTaken = false; StaticPictureState.checkpointBodies = 0;
    StaticPictureState.bodyRequests = 0; StaticPictureTrace.start();
    StaticPictureState.pageRequests = []; StaticPictureState.bodyIds.clear();
    StaticPictureState.expectedBodies.clear(); StaticPictureState.expectedDocuments.clear();
    StaticPictureState.savedDocument = undefined; StaticPictureState.expectedDocument = '';
    PictureCache.setForeground(true);
    StaticPictureState.requests = 0; StaticPictureState.nonContentRequests = 0; StaticPictureState.held = true;
    StaticPictureState.missingReady = false; StaticPictureState.unavailable = false;
    StaticPictureState.counts.clear(); StaticPictureState.savedAt.clear();
    const server = socket.constructTCPSocketServerInstance(); StaticPictureState.server = server;
    server.on('connect', connection => StaticPictureState.accept(connection));
    server.on('error', () => { StaticPictureState.recordTrace('server_error'); StaticPictureState.release(); });
    try {
      await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
      const address = await server.getLocalAddress();
      if (address.address !== '127.0.0.1' || !address.port) { throw new Error('Fixture must bind loopback'); }
      StaticPictureState.url = `http://127.0.0.1:${address.port}`;
      StaticPictureState.deadline = setTimeout(() => { StaticPictureState.release(); StaticPictureState.stopServer().catch(() => {}); }, 90000);
      await relationalStore.deleteRdbStore(context, StaticPictureState.dbName).catch(() => {});
      const store = new AccountStore(StaticPictureState.dbName); StaticPictureState.store = store;
      await store.open(context);
      // This dummy credential belongs only to the isolated synthetic account.
      // The service below never reads it or contacts a mail server.
      const account = await store.add('https://snapshot.example.test/jmap',
        { id: 'synthetic-server', name: 'Synthetic static pictures', isPersonal: true, isReadOnly: false },
        'synthetic', 'reader@example.test');
      StaticPictureState.account = account; StaticPictureState.accountId = account.id;
      const body = StaticPictureState.body(); StaticPictureState.messageKey = stableMessageKey(body);
      StaticPictureState.expectedBody = body.htmlBody || '';
      StaticPictureState.cache = store.pictures;
      StaticPictureState.png = await context.resourceManager.getRawFileContent('picture-refresh.png');
      StaticPictureState.replacement = await context.resourceManager.getRawFileContent('picture-refresh-replacement.png');
      const worker = new MailBodySync(store, (): boolean => StaticPictureState.syncMayRun());
      StaticPictureState.worker = worker;
      const client = new StaticPictureClient();
      const firstPage = await client.emailPage(account.serverId, 'inbox', 0);
      await store.mail.saveView(account.id, 'inbox', firstPage.emails, firstPage.nextPosition, firstPage.queryState);
      await worker.enqueuePage(client, account, 'inbox', firstPage, 'Show quoted text', 'Hide quoted text');
      await worker.whenIdle();
      // Stop partway through the initial page, including the worker and its
      // encrypted store. No reader has mounted and older pages remain unseen.
      const checkpoint = await store.mail.cachedMessages(account.id);
      StaticPictureState.checkpointBodies = checkpoint.filter(value => value.bodySavedAt !== null).length;
      if (!StaticPictureState.checkpointTaken || StaticPictureState.checkpointBodies !== 2 ||
        StaticPictureState.bodyRequests !== 2 || StaticPictureState.pageRequests.join(',') !== '0') {
        throw new Error('Synthetic checkpoint did not retain incomplete sync');
      }
      await StaticPictureState.reopenStore(false);
      const resumedStore = StaticPictureState.store;
      if (!resumedStore) { throw new Error('Synthetic sync store did not reopen'); }
      const cachedPage = await resumedStore.mail.view(account.id, 'inbox', true, false);
      if (!cachedPage) { throw new Error('Synthetic cursor disappeared at checkpoint'); }
      StaticPictureState.syncAllowed = true;
      const resumedWorker = new MailBodySync(resumedStore, (): boolean => StaticPictureState.syncMayRun());
      StaticPictureState.worker = resumedWorker;
      await resumedWorker.enqueueCached(client, account, 'inbox', cachedPage, 'Show quoted text', 'Hide quoted text');
      await resumedWorker.whenIdle();
      await StaticPictureState.captureCompleteMail();
      const prepared = await resumedStore.documents.read(account.id, StaticPictureState.messageKey);
      if (!prepared.document || prepared.document.pictures.length !== 3) { throw new Error('Sync did not save synthetic document'); }
      StaticPictureState.expectedDocument = JSON.stringify(prepared.document);
      // All network sources are unavailable before the reader can be mounted.
      StaticPictureState.sealed = true; StaticPictureState.makeUnavailable();
      await StaticPictureState.recreateCache();
      if (!await StaticPictureState.documentIntact() || !await StaticPictureState.cacheIntact(1)) {
        throw new Error('Synthetic sync did not persist its body, HTML and picture');
      }
    } catch (error) { await StaticPictureState.close(); throw error as Error; }
  }

  private static syncMayRun(): boolean {
    return StaticPictureState.fixtureOpen && StaticPictureState.syncAllowed && !StaticPictureState.sealed;
  }
  static body(emailId: string = StaticPictureState.emailId): JmapEmail {
    const main = emailId === StaticPictureState.emailId;
    return { id: emailId, threadId: emailId,
      messageIds: [emailId + '@example.test'], mailboxIds: ['inbox'], keywords: ['$seen'],
      from: [{ name: 'Synthetic sender', email: 'sender@example.test' }], to: [{ name: '', email: 'reader@example.test' }], replyTo: [],
      subject: main ? 'Synthetic static pictures' : 'Synthetic complete message ' + emailId,
      preview: 'Saved sync fixture', receivedAt: 100000 - StaticPictureState.emailIds.indexOf(emailId),
      textBody: 'Synthetic saved body ' + emailId,
      htmlBody: main ? StaticPictureState.document() : '<p>Complete saved body for ' + emailId + '.</p>', hasAttachment: false,
      hasHtmlBody: true, bodyTruncated: false, bodyEncodingProblem: false };
  }
  static page(accountId: string, mailboxId: string, position: number = 0, queryState?: string): JmapEmailPage {
    if (StaticPictureState.sealed || accountId !== 'synthetic-server' || mailboxId !== 'inbox' ||
      ![0, 3, 6].includes(position) || (position > 0 && queryState !== StaticPictureState.pageState)) {
      throw new Error('Unexpected synthetic page request');
    }
    StaticPictureState.pageRequests.push(position);
    const emails = StaticPictureState.emailIds.slice(position, position + 3).map((id): JmapEmail => {
      const mail = StaticPictureState.body(id); mail.textBody = null; mail.htmlBody = null; return mail;
    });
    return { accountId, queryState: StaticPictureState.pageState, emailState: StaticPictureState.pageState,
      position, nextPosition: position < 6 ? position + 3 : null, total: StaticPictureState.emailIds.length,
      emails, notFound: [] };
  }
  static readBody(emailId: string): JmapEmail {
    ++StaticPictureState.bodyRequests;
    if (StaticPictureState.sealed || !StaticPictureState.emailIds.includes(emailId) || StaticPictureState.bodyIds.has(emailId)) {
      throw new Error('Body source is offline or was downloaded twice');
    }
    StaticPictureState.bodyIds.add(emailId);
    if (!StaticPictureState.checkpointTaken && StaticPictureState.bodyRequests === 2) {
      StaticPictureState.checkpointTaken = true; StaticPictureState.syncAllowed = false;
    }
    return StaticPictureState.body(emailId);
  }
  static recordScan(): void { StaticPictureTrace.recordScan(); }
  static recordBatch(): void { StaticPictureTrace.recordBatch(); }
  static workCounts(): string { return `${StaticPictureState.bodyRequests},${StaticPictureTrace.counts()}`; }
  static syncCounts(): string {
    return `pages=${StaticPictureState.pageRequests.join(',')} checkpoint=${StaticPictureState.checkpointBodies}/7 saved=${StaticPictureState.expectedBodies.size}/7`;
  }
  private static async captureCompleteMail(): Promise<void> {
    const store = StaticPictureState.store;
    if (!store || StaticPictureState.pageRequests.join(',') !== '0,3,6' || StaticPictureState.bodyRequests !== 7 ||
      StaticPictureState.bodyIds.size !== 7) { throw new Error('Synthetic sync did not traverse every mailbox page'); }
    for (const id of StaticPictureState.emailIds) {
      const body = await store.mail.email(StaticPictureState.accountId, id, true);
      const expected = StaticPictureState.body(id);
      const prepared = await store.documents.read(StaticPictureState.accountId, stableMessageKey(expected));
      if (!body || body.bodySavedAt === null || body.mail.htmlBody !== expected.htmlBody ||
        body.mail.textBody !== expected.textBody || !prepared.document ||
        prepared.document.bodySavedAt !== body.bodySavedAt) {
        throw new Error('Synthetic sync left an incomplete saved message');
      }
      StaticPictureState.expectedBodies.set(id, JSON.stringify(body));
      StaticPictureState.expectedDocuments.set(id, JSON.stringify(prepared.document));
    }
  }
  static savedDocumentReady(): boolean { return StaticPictureState.savedDocument !== undefined; }
  static async documentIntact(): Promise<boolean> {
    const store = StaticPictureState.store;
    if (!store || !StaticPictureState.savedDocument) { return false; }
    if (StaticPictureState.expectedBodies.size !== 7 || StaticPictureState.expectedDocuments.size !== 7) { return false; }
    for (const id of StaticPictureState.emailIds) {
      const cached = await store.mail.email(StaticPictureState.accountId, id, true);
      const document = await store.documents.read(StaticPictureState.accountId, stableMessageKey(StaticPictureState.body(id)));
      if (JSON.stringify(cached) !== StaticPictureState.expectedBodies.get(id) ||
        JSON.stringify(document.document) !== StaticPictureState.expectedDocuments.get(id)) { return false; }
    }
    const result = await store.documents.read(StaticPictureState.accountId, StaticPictureState.messageKey);
    const body = await store.mail.email(StaticPictureState.accountId, StaticPictureState.emailId, true);
    return result.document !== null && JSON.stringify(result.document) === StaticPictureState.expectedDocument &&
      JSON.stringify(StaticPictureState.savedDocument) === StaticPictureState.expectedDocument &&
      body?.mail.htmlBody === StaticPictureState.expectedBody && StaticPictureState.savedBody === StaticPictureState.expectedBody &&
      result.document.pictures.every(picture => result.document!.html.includes(picture.id));
  }

  static scene: number = 0;
  private static active: boolean = false;
  private static mounts: number = 0;
  private static documents: number = 0;
  private static scrollMaximum: number = 0;
  private static traceStages: string[] = [];
  private static scrollTop: () => void = () => {};

  private static resetScene(): void {
    ++StaticPictureState.scene; StaticPictureState.active = false;
    StaticPictureState.mounts = 0; StaticPictureState.documents = 0;
    StaticPictureState.scrollMaximum = 0; StaticPictureState.traceStages = [];
  }
  static beginScene(): void { ++StaticPictureState.scene; StaticPictureState.active = false; }
  static setActive(scene: number, active: boolean): void {
    if (scene === StaticPictureState.scene) {
      StaticPictureState.active = active;
      if (!active) { StaticPictureState.scrollTop = () => {}; }
    }
  }
  static setScrollTop(scene: number, action: () => void): void {
    if (scene === StaticPictureState.scene) { StaticPictureState.scrollTop = action; }
  }
  static returnToTop(): void { StaticPictureState.scrollTop(); }
  static recordMount(scene: number): void {
    if (scene === StaticPictureState.scene && StaticPictureState.active) { ++StaticPictureState.mounts; }
  }
  static recordDocument(scene: number): void {
    if (scene === StaticPictureState.scene && StaticPictureState.active) { ++StaticPictureState.documents; }
  }
  static recordScroll(scene: number, offset: number): void {
    if (scene === StaticPictureState.scene && StaticPictureState.active && Number.isFinite(offset)) {
      StaticPictureState.scrollMaximum = Math.max(StaticPictureState.scrollMaximum, offset);
    }
  }
  static maximumScroll(): number { return StaticPictureState.scrollMaximum; }
  static loadCounts(): string { return `${StaticPictureState.mounts},${StaticPictureState.documents}`; }
  private static recordTrace(stage: string): void {
    if (StaticPictureState.traceStages.length < 120) { StaticPictureState.traceStages.push(stage); }
  }
  static setForeground(foreground: boolean): void { PictureCache.setForeground(foreground); }
  static async recreateCache(): Promise<void> {
    await StaticPictureState.reopenStore(true);
  }
  private static async reopenStore(readerReady: boolean): Promise<void> {
    const worker = StaticPictureState.worker; StaticPictureState.worker = undefined;
    if (worker) { await worker.close(); }
    const store = StaticPictureState.store; StaticPictureState.store = undefined;
    if (store) { await store.close(); }
    const old = StaticPictureState.db; StaticPictureState.db = undefined;
    if (old) { try { await old.close(); } catch (_) {} }
    const context = StaticPictureState.context;
    if (!context || !StaticPictureState.account) { throw new Error('Synthetic storage context is not open'); }
    const reopened = new AccountStore(StaticPictureState.dbName); await reopened.open(context);
    StaticPictureState.store = reopened; StaticPictureState.cache = reopened.pictures;
    if (readerReady) {
      const prepared = await reopened.documents.read(StaticPictureState.accountId, StaticPictureState.messageKey);
      const body = await reopened.mail.email(StaticPictureState.accountId, StaticPictureState.emailId, true);
      if (!prepared.document || !body) { throw new Error('Saved synthetic document disappeared'); }
      StaticPictureState.savedDocument = prepared.document; StaticPictureState.savedBody = body.mail.htmlBody || '';
    }
    StaticPictureState.db = await relationalStore.getRdbStore(context, {
      name: StaticPictureState.dbName, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    StaticPictureState.beginScene();
  }
  static document(): string {
    let html = '<h2>Synthetic static pictures</h2><p>Body and pictures were synchronized before opening.</p>' +
      `<div><img src="${StaticPictureState.url}/good.png" width="240" height="72" alt="Synthetic good colors"></div>` +
      `<div><img src="${StaticPictureState.url}/connection.png" width="240" height="72" alt="Synthetic connection recovery"></div>` +
      `<div><img src="${StaticPictureState.url}/server.png" width="240" height="72" alt="Synthetic server recovery"></div>` +
      `<img src="${StaticPictureState.url}/tracking.gif" width="1" height="1">` +
      `<img src="${StaticPictureState.url}/hidden.png" style="display:none!important">`;
    for (let row = 0; row < 100; row++) {
      html += `<p>Static snapshot row ${row}: saved synthetic text remains unchanged while scrolling.</p>`;
    }
    if (html.length * 3 > 65536) { throw new Error('Synthetic document exceeded byte budget'); }
    return html;
  }

  static trace(): string { return StaticPictureState.traceStages.join(','); }
  static requestCounts(): string {
    return StaticPictureState.paths.map(path => StaticPictureState.counts.get(path) || 0).join(',');
  }

  private static accept(connection: socket.TCPSocketConnection): void {
    StaticPictureState.recordTrace('http_connection');
    if (StaticPictureState.clients.size >= 4 || !StaticPictureState.url) { connection.close().catch(() => {}); return; }
    const client = new StaticPictureConnection(connection);
    StaticPictureState.clients.set(connection.clientId, client);
    client.timer = setTimeout(() => StaticPictureState.drop(client), 15000);
    connection.on('close', () => StaticPictureState.drop(client));
    connection.on('error', () => { StaticPictureState.recordTrace('http_error'); StaticPictureState.drop(client); });
    connection.on('message', info => {
      if (client.ready || client.bytes.length + info.message.byteLength > 8192) { StaticPictureState.drop(client); return; }
      client.bytes += new util.TextDecoder().decodeToString(new Uint8Array(info.message));
      if (!client.bytes.includes('\r\n\r\n')) { return; }
      const authority = StaticPictureState.url.split('/')[2];
      const path = StaticPictureState.paths.concat(StaticPictureState.nonContentPaths)
        .find(value => client.bytes.startsWith(`GET ${value} HTTP/1.`));
      const requestLineValid = path !== undefined;
      const hostValid = client.bytes.toLowerCase().includes(`\r\nhost: ${authority}\r\n`);
      StaticPictureState.recordTrace(requestLineValid ? 'request_line_valid' : 'request_line_invalid');
      StaticPictureState.recordTrace(hostValid ? 'host_valid' : 'host_invalid');
      if (!path || !hostValid) { StaticPictureState.drop(client); return; }
      client.path = path;
      client.ready = true; StaticPictureState.requests++;
      if (StaticPictureState.nonContentPaths.includes(path)) { StaticPictureState.nonContentRequests++; }
      StaticPictureState.counts.set(path, (StaticPictureState.counts.get(path) || 0) + 1);
      if (!StaticPictureState.held) { StaticPictureState.respond(client); }
    });
  }

  private static drop(client: StaticPictureConnection): void {
    if (!StaticPictureState.clients.delete(client.connection.clientId)) { return; }
    clearTimeout(client.timer);
    client.connection.off('message'); client.connection.off('close'); client.connection.off('error');
    client.connection.close().catch(() => {});
  }

  private static respond(client: StaticPictureConnection): void {
    if (client.responding) { return; }
    client.responding = true;
    const missing = client.path !== '/good.png' && !StaticPictureState.missingReady;
    if (missing && client.path === '/connection.png' && !StaticPictureState.unavailable) {
      StaticPictureState.recordTrace('http_connection_failed'); StaticPictureState.drop(client); return;
    }
    // These two invisible references never recover. Filtering must prevent
    // their requests and warnings, including on explicit retry and remount.
    const failed = StaticPictureState.unavailable || missing || StaticPictureState.nonContentPaths.includes(client.path);
    StaticPictureState.recordTrace(failed ? 'http_503' : 'http_200');
    const body = failed ? new Uint8Array() :
      (client.path === '/good.png' ? StaticPictureState.png : StaticPictureState.replacement);
    const header = new util.TextEncoder().encodeInto(`HTTP/1.1 ${failed ? '503 Service Unavailable' : '200 OK'}\r\nContent-Type: ${failed ? 'text/plain' : 'application/octet-stream'}\r\nContent-Length: ${body.byteLength}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n`);
    const response = new Uint8Array(header.byteLength + body.byteLength);
    response.set(header); response.set(body, header.byteLength);
    client.connection.send({ data: response.buffer as ArrayBuffer })
      .catch(() => { StaticPictureState.recordTrace('http_send_failed'); }).then(() => StaticPictureState.drop(client));
  }

  static holdFailures(): void { StaticPictureState.held = true; }
  static recoverMissing(): void { StaticPictureState.missingReady = true; StaticPictureState.unavailable = false; }
  // Keep a loopback sentinel listening so even an attempted cached-image
  // re-download is counted. Every resource is now unavailable (HTTP503).
  static makeUnavailable(): void { StaticPictureState.unavailable = true; }

  static release(): void {
    StaticPictureState.held = false;
    for (const client of StaticPictureState.clients.values()) { if (client.ready) { StaticPictureState.respond(client); } }
  }

  static async cacheIntact(expectedCount: number): Promise<boolean> {
    if (!StaticPictureState.db) { return false; }
    const rows = await StaticPictureState.db.querySql('SELECT data, saved_at, mime_type, url FROM picture_cache WHERE account_id = ? AND message_key = ?',
      [StaticPictureState.accountId, StaticPictureState.messageKey]);
    try {
      let count = 0;
      while (rows.goToNextRow()) {
        const url = rows.getString(3), path = url.slice(StaticPictureState.url.length);
        if (!url.startsWith(StaticPictureState.url) || !StaticPictureState.paths.includes(path) ||
          (expectedCount === 1 && path !== '/good.png') || rows.getString(2) !== 'image/png') { return false; }
        const expected = path === '/good.png' ? StaticPictureState.png : StaticPictureState.replacement;
        const actual = rows.getBlob(0), savedAt = rows.getLong(1);
        if (actual.length !== expected.length || !actual.every((value, index) => value === expected[index])) { return false; }
        if (!StaticPictureState.savedAt.has(path)) { StaticPictureState.savedAt.set(path, savedAt); }
        if (savedAt <= 0 || savedAt !== StaticPictureState.savedAt.get(path)) { return false; }
        count++;
      }
      return count === expectedCount;
    } finally { rows.close(); }
  }

  private static async stopServer(): Promise<void> {
    clearTimeout(StaticPictureState.deadline);
    for (const client of Array.from(StaticPictureState.clients.values())) { StaticPictureState.drop(client); }
    const server = StaticPictureState.server; StaticPictureState.server = undefined;
    if (server) { server.off('connect'); server.off('error'); await server.close(); }
  }

  static async close(): Promise<void> {
    StaticPictureTrace.stop();
    StaticPictureState.active = false; StaticPictureState.fixtureOpen = false; StaticPictureState.scrollTop = () => {};
    StaticPictureState.release(); await StaticPictureState.stopServer();
    const worker = StaticPictureState.worker; StaticPictureState.worker = undefined;
    if (worker) { await worker.close(); }
    const store = StaticPictureState.store; StaticPictureState.store = undefined;
    if (store) {
      if (StaticPictureState.account) { await store.remove(StaticPictureState.account.id).catch(() => {}); }
      await store.close();
    }
    const db = StaticPictureState.db; StaticPictureState.db = undefined;
    if (db) { try { await db.close(); } catch (_) {} }
    StaticPictureState.cache = undefined; StaticPictureState.savedDocument = undefined; StaticPictureState.account = undefined;
    StaticPictureState.context = undefined; StaticPictureState.url = ''; PictureCache.setForeground(true);
  }
}
