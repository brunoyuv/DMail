// This service has no socket, HTTP, credential, notification or SMTP access.
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountStore } from '../data/AccountStore';
import { MailContentFiles } from '../data/MailContentFiles';
import { mailContentReferenceValid } from '../data/MailContentFileModel';
import { PictureCache } from '../data/PictureCache';
import { stableMessageKey } from '../mail/Conversation';
import { MailInboxUpdates } from '../mail/notifications/MailInboxUpdates';
import { InboxIdleTrace } from './InboxIdleTrace';
import { JmapAccount, JmapArchiveUndo, JmapClientFactory, JmapCreatedDraft, JmapCredentials,
  JmapDraft, JmapEmail, JmapEmailPage, JmapKeyword, JmapMailbox, JmapService, JmapSession } from '../mail/jmap/JmapClient';

export class InboxIdleState {
  static readonly count: number = 16;
  static store: AccountStore = new AccountStore('inbox_idle_fixture.db');
  static accountId: string = '';
  private static bodies: string[] = [];
  private static bodyTimes: number[] = [];
  private static pages: number = 0;
  private static violations: number = 0;
  private static sealed: boolean = false;
  private static navigationMessage: boolean = false;
  private static pictureHtml: string = '';

  // One disposable synthetic row demonstrates the native ResultSet boundary.
  // Only its length and numeric error code leave this fixture.
  static async largeRowProof(context: common.Context): Promise<string> {
    const name = 'inbox_idle_large_row_probe.db';
    const db = await relationalStore.getRdbStore(context, {
      name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    let characters = 0, code = 0, direct = false;
    try {
      await db.executeSql('CREATE TABLE IF NOT EXISTS probe (payload TEXT NOT NULL)');
      await db.executeSql('DELETE FROM probe');
      await db.executeSql('INSERT INTO probe (payload) VALUES (?)', ['x'.repeat(3 * 1024 * 1024)]);
      const length = await db.querySql('SELECT length(payload) FROM probe');
      try { if (length.goToFirstRow()) { characters = length.getLong(0); } } finally { length.close(); }
      try {
        const rows = await db.querySql('SELECT payload FROM probe');
        try { direct = rows.goToFirstRow() && rows.getString(0).length === characters; } finally { rows.close(); }
      } catch (error) {
        const value = (error as BusinessError).code;
        code = Number.isSafeInteger(value) ? value : -1;
      }
    } finally {
      await db.close(); await relationalStore.deleteRdbStore(context, name);
    }
    return `characters=${characters} direct_read=${direct} error_code=${code}`;
  }

  static async reopen(context: common.Context): Promise<void> {
    InboxIdleState.setForeground(false);
    await InboxIdleState.store.close();
    InboxIdleState.store = new AccountStore('inbox_idle_fixture.db');
    await InboxIdleState.store.open(context);
    InboxIdleState.setForeground(true);
  }

  static async storageProof(context: common.Context): Promise<string> {
    if (!InboxIdleState.sealed || InboxIdleState.bodies.length !== 1) { throw new Error('Synthetic body is not sealed'); }
    const db = await relationalStore.getRdbStore(context, {
      name: 'inbox_idle_fixture.db', securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    let rawBytes = 0, preparedBytes = 0, reference = '';
    try {
      const raw = await db.querySql("SELECT MAX(length(CAST(payload AS BLOB))) FROM mail_cache WHERE account_id = ? AND kind = 'email'",
        [InboxIdleState.accountId]);
      try { if (raw.goToFirstRow()) { rawBytes = raw.getLong(0); } } finally { raw.close(); }
      const prepared = await db.querySql('SELECT length(CAST(payload AS BLOB)), json_extract(payload, \'$.htmlFile\') FROM prepared_documents WHERE account_id = ? AND message_key = ?',
        [InboxIdleState.accountId, stableMessageKey(InboxIdleState.mail(Number(InboxIdleState.bodies[0].slice(5))))]);
      try {
        if (prepared.goToFirstRow()) { preparedBytes = prepared.getLong(0); reference = prepared.getString(1); }
      } finally { prepared.close(); }
    } finally { await db.close(); }
    if (rawBytes <= 0 || rawBytes >= 65536 || preparedBytes <= 0 || preparedBytes >= 65536 ||
      !mailContentReferenceValid(InboxIdleState.accountId, reference, 'html')) { throw new Error('Synthetic file metadata was not saved'); }
    const html = await new MailContentFiles(context.filesDir).read(InboxIdleState.accountId, reference, 8 * 1024 * 1024);
    if (html.length < 6 * 1000 * 1000 || html.split('data:image/png;base64,').length !== 21) {
      throw new Error('Synthetic HTML file is incomplete');
    }
    return `raw_db_bytes=${rawBytes} prepared_db_bytes=${preparedBytes} html_file=true prepared_html_characters=${html.length}`;
  }

  static async open(context: common.Context): Promise<void> {
    InboxIdleTrace.stop(); MailInboxUpdates.setForeground(false);
    await InboxIdleState.store.open(context);
    for (const account of await InboxIdleState.store.list()) { await InboxIdleState.store.remove(account.id); }
    const identity: JmapAccount = { id: 'inbox-idle-server', name: 'Synthetic idle Inbox', isPersonal: true, isReadOnly: false };
    const account = await InboxIdleState.store.add('https://idle.example.test/jmap', identity,
      'synthetic-inbox-idle-only', 'reader@example.test');
    InboxIdleState.accountId = account.id;
    InboxIdleState.navigationMessage = false;
    const sections: string[] = [];
    const encoder = new util.Base64Helper();
    for (let index = 0; index < 20; index++) {
      const bytes = await context.resourceManager.getRawFileContent(`picture-scroll/picture-${index}.png`);
      if (bytes.length < 100 || bytes.length > 1024 * 1024) { throw new Error('Synthetic picture resource exceeds budget'); }
      sections.push(`<figure><img src="data:image/png;base64,${encoder.encodeToStringSync(bytes)}" width="800" height="450" alt="Synthetic landscape ${index}"><figcaption>Cached synthetic picture ${index}</figcaption></figure>`);
      for (let row = 0; row < 60; row++) {
        sections.push(`<p>Physics newsletter section ${index}, paragraph ${row}: bounded synthetic text with Unicode 中文 café. An immutable local HTML message for scrolling.</p>`);
      }
    }
    InboxIdleState.pictureHtml = sections.join('');
    if (InboxIdleState.pictureHtml.length > 7 * 1024 * 1024) { throw new Error('Synthetic HTML exceeds cache budget'); }
    await InboxIdleState.store.mail.saveBoxes(account.id, [InboxIdleState.box()], false);
    const page = InboxIdleState.page();
    await InboxIdleState.store.mail.saveView(account.id, 'inbox', page.emails, null, page.queryState);
    await InboxIdleState.store.rememberVisitedAccount(account.id);
    InboxIdleState.bodies = []; InboxIdleState.bodyTimes = []; InboxIdleState.pages = 0;
    InboxIdleState.violations = 0; InboxIdleState.sealed = false;
    InboxIdleTrace.start(); InboxIdleState.setForeground(true);
  }
  static async close(context: common.Context): Promise<void> {
    InboxIdleState.setForeground(false); InboxIdleTrace.stop();
    // Keep the old component's delayed close tied to its old handle.
    await InboxIdleState.store.close();
    InboxIdleState.store = new AccountStore('inbox_idle_fixture.db');
    await InboxIdleState.store.open(context);
    for (const account of await InboxIdleState.store.list()) { await InboxIdleState.store.remove(account.id); }
    await InboxIdleState.store.close(); InboxIdleState.accountId = ''; InboxIdleState.pictureHtml = '';
  }
  static box(): JmapMailbox {
    return { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
      totalEmails: InboxIdleState.total(), unreadEmails: 0, maySetSeen: true, maySetKeywords: true,
      mayAddItems: true, mayRemoveItems: true };
  }
  static mail(index: number, body: boolean = false): JmapEmail {
    const id = `idle-${index.toString().padStart(2, '0')}`;
    return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds: ['inbox'], keywords: ['$seen'],
      from: [{ name: 'Synthetic sender', email: 'sender@example.test' }], to: [], cc: [], replyTo: [],
      subject: `Synthetic Inbox message ${index}`, preview: 'The body downloads only when this synthetic message is opened',
      receivedAt: index === InboxIdleState.count ? 1789293660000 : 1789293600000 - index * 60000, hasAttachment: false,
      textBody: body ? `Saved synthetic body ${index}` : null,
      htmlBody: body ? `<html><body><h2>Synthetic body ${index}</h2>${InboxIdleState.pictureHtml}</body></html>` : null,
      hasHtmlBody: true, bodyTruncated: false, bodyEncodingProblem: false, maySetSeen: true, maySetKeywords: true };
  }
  static page(): JmapEmailPage {
    const emails: JmapEmail[] = [];
    if (InboxIdleState.navigationMessage) { emails.push(InboxIdleState.mail(InboxIdleState.count)); }
    for (let index = 0; index < InboxIdleState.count; index++) { emails.push(InboxIdleState.mail(index)); }
    return { accountId: 'inbox-idle-server', emails, position: 0, nextPosition: null,
      queryState: InboxIdleState.navigationMessage ? 'inbox-idle-navigation-head' : 'inbox-idle-stable-head',
      emailState: 'inbox-idle-state', total: emails.length, notFound: [] };
  }
  static header(accountId: string, mailboxId: string, position: number = 0): JmapEmailPage {
    if (accountId !== 'inbox-idle-server' || mailboxId !== 'inbox' || position !== 0) { return InboxIdleState.unexpected(); }
    ++InboxIdleState.pages; return InboxIdleState.page();
  }
  static async body(accountId: string, emailId: string): Promise<JmapEmail> {
    const index = Number(emailId.slice(5));
    if (InboxIdleState.sealed || accountId !== 'inbox-idle-server' || !Number.isInteger(index) || index < 0 ||
      index >= InboxIdleState.total() || InboxIdleState.mail(index).id !== emailId || InboxIdleState.bodies.includes(emailId)) {
      return InboxIdleState.unexpected();
    }
    InboxIdleState.bodies.push(emailId); InboxIdleState.bodyTimes.push(Date.now());
    return InboxIdleState.mail(index, true);
  }
  static unexpected(): never { ++InboxIdleState.violations; throw new Error('Unexpected synthetic idle operation'); }
  static completed(): number { return InboxIdleTrace.completedCount(); }
  static counts(): string {
    return `${InboxIdleTrace.counts()},${InboxIdleState.bodies.length},${InboxIdleState.pages},${InboxIdleState.violations},${InboxIdleTrace.visibilityCounts()}`;
  }
  static times(): string { return InboxIdleState.bodyTimes.join(','); }
  static requestUpdate(): void { MailInboxUpdates.request(InboxIdleState.accountId); }
  static setForeground(visible: boolean): void {
    PictureCache.setForeground(visible); MailInboxUpdates.setForeground(visible);
  }
  private static total(): number { return InboxIdleState.count + (InboxIdleState.navigationMessage ? 1 : 0); }
  // A fixture-only arrival updates headers; it must never request the new body.
  static advanceNavigation(): void {
    if (InboxIdleState.navigationMessage) { return; }
    InboxIdleState.navigationMessage = true; InboxIdleState.sealed = false;
    InboxIdleState.requestUpdate();
  }
  static async sealAndVerify(): Promise<boolean> {
    if (InboxIdleState.bodies.length !== 1 || InboxIdleTrace.completedCount() !== 1) { return false; }
    for (const id of InboxIdleState.bodies) {
      const index = Number(id.slice(5));
      const expected = InboxIdleState.mail(index, true);
      const saved = await InboxIdleState.store.mail.email(InboxIdleState.accountId, expected.id, true);
      const document = await InboxIdleState.store.documents.read(InboxIdleState.accountId, stableMessageKey(expected));
      if (!saved || saved.bodySavedAt === null || saved.mail.htmlBody !== expected.htmlBody ||
        !document.document || !document.document.html.includes(`Synthetic body ${index}`) ||
        document.document.html.split('data:image/png;base64,').length !== 21 || document.document.pictures.length !== 0) { return false; }
    }
    InboxIdleState.sealed = true; return true;
  }
}

class InboxIdleClient implements JmapService {
  async connect(): Promise<JmapSession> { return InboxIdleState.unexpected(); }
  async mailboxes(_accountId: string): Promise<JmapMailbox[]> { return InboxIdleState.unexpected(); }
  async emailPage(accountId: string, mailboxId: string, position?: number, _queryState?: string): Promise<JmapEmailPage> {
    return InboxIdleState.header(accountId, mailboxId, position);
  }
  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> { return InboxIdleState.body(accountId, emailId); }
  async createDraft(_accountId: string, _draft: JmapDraft): Promise<JmapCreatedDraft> { return InboxIdleState.unexpected(); }
  async setKeyword(_accountId: string, _emailId: string, _keyword: JmapKeyword, _enabled: boolean): Promise<string> { return InboxIdleState.unexpected(); }
  async archiveEmail(_accountId: string, _emailId: string): Promise<JmapArchiveUndo> { return InboxIdleState.unexpected(); }
  async undoArchive(_undo: JmapArchiveUndo): Promise<void> { InboxIdleState.unexpected(); }
}
export class InboxIdleClientFactory implements JmapClientFactory {
  create(endpoint: string, _credentials: JmapCredentials): JmapService {
    if (endpoint !== 'https://idle.example.test/jmap') { return InboxIdleState.unexpected(); }
    return new InboxIdleClient();
  }
}
