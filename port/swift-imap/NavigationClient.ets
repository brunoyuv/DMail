// Test-only in-memory mail service. It never opens a socket or reads credentials.
import { JmapAccount, JmapArchiveUndo, JmapClientFactory, JmapCreatedDraft, JmapCredentials,
  JmapDraft, JmapEmail, JmapEmailPage, JmapError, JmapKeyword, JmapMailbox, JmapService,
  JmapSession } from '../../../main/ets/mail/jmap/JmapClient';

export class NavigationFixtureState {
  static betaOffline: boolean = false;
  static alphaPages: number = 0;
  static betaPages: number = 0;
  static betaInboxSize: number | null = null;
  static readerRecovery: boolean = false;
  static readerAttempts: number = 0;
  static created: string[] = [];
  static calls: string[] = [];
  static violations: string[] = [];
  static holdKeywords: boolean = false;
  static repeatKeywordActions: boolean = false;
  static pendingKeywords: number = 0;
  private static keywordCompletion: (() => void) | null = null;
  static completeKeywords(): void {
    const completion = NavigationFixtureState.keywordCompletion;
    NavigationFixtureState.keywordCompletion = null;
    if (completion) { completion(); }
  }
  static async waitKeywordCompletion(): Promise<void> {
    if (!NavigationFixtureState.holdKeywords) { return; }
    NavigationFixtureState.pendingKeywords++;
    await new Promise<void>(resolve => { NavigationFixtureState.keywordCompletion = resolve; });
    NavigationFixtureState.pendingKeywords--;
  }
  static reset(): void {
    NavigationFixtureState.completeKeywords();
    NavigationFixtureState.holdKeywords = false;
    NavigationFixtureState.repeatKeywordActions = false;
    NavigationFixtureState.pendingKeywords = 0;
    NavigationFixtureState.betaOffline = false;
    NavigationFixtureState.alphaPages = 0;
    NavigationFixtureState.betaPages = 0;
    NavigationFixtureState.betaInboxSize = null;
    NavigationFixtureState.readerRecovery = false;
    NavigationFixtureState.readerAttempts = 0;
    NavigationFixtureState.created = [];
    NavigationFixtureState.calls = [];
    NavigationFixtureState.violations = [];
  }
}
export function navigationAccount(name: string): JmapAccount {
  return { id: 'shared-account', name, isPersonal: true, isReadOnly: false };
}
export function navigationMailbox(): JmapMailbox {
  return { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
    totalEmails: 80, unreadEmails: 0, maySetSeen: true, maySetKeywords: true,
    mayAddItems: true, mayRemoveItems: true };
}
export function navigationMail(label: string, index: number, revision: number, cached: boolean = false): JmapEmail {
  const number = index.toString().padStart(2, '0');
  return { id: `mail-${number}`, threadId: `thread-${number}`, messageIds: [`${label}-${number}@example.test`],
    mailboxIds: ['inbox'], keywords: !cached && index === 0 ? [] : ['$seen'], from: [{ name: `${label} sender`, email: `${label.toLowerCase()}@example.test` }],
    to: [{ name: 'Reader', email: 'reader@example.test' }], replyTo: [],
    subject: cached ? `${label} cached message ${number}` : `${label} message ${number} revision ${revision}`,
    preview: `${label} synthetic preview ${number}`, receivedAt: 1789293600000 - index * 60000,
    hasAttachment: false, textBody: cached ? `${label} cached body` : null, htmlBody: null,
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false,
    maySetSeen: true, maySetKeywords: true };
}
class NavigationClient implements JmapService {
  private label: string;
  constructor(label: string) { this.label = label; }
  private available(accountId: string = 'shared-account'): void {
    if (accountId !== 'shared-account') {
      NavigationFixtureState.violations.push('Wrong account ID');
      throw new JmapError('invalidResponse');
    }
    if (this.label === 'Beta' && NavigationFixtureState.betaOffline) { throw new JmapError('network'); }
  }
  async connect(): Promise<JmapSession> {
    NavigationFixtureState.calls.push(`${this.label}:connect`);
    this.available();
    return { apiUrl: `https://${this.label.toLowerCase()}.example.test/api`, state: 'fixture',
      accounts: [navigationAccount(this.label)], primaryAccountId: 'shared-account', maxObjectsInGet: 100 };
  }
  async mailboxes(accountId: string): Promise<JmapMailbox[]> {
    NavigationFixtureState.calls.push(`${this.label}:mailboxes`);
    this.available(accountId); return [navigationMailbox()];
  }
  async emailPage(accountId: string, mailboxId: string, position: number = 0, _queryState?: string): Promise<JmapEmailPage> {
    NavigationFixtureState.calls.push(`${this.label}:emailPage`);
    this.available(accountId);
    if (mailboxId !== 'inbox' || position !== 0) {
      NavigationFixtureState.violations.push('Wrong mailbox or page');
      throw new JmapError('invalidResponse');
    }
    const revision = this.label === 'Alpha' ? ++NavigationFixtureState.alphaPages : ++NavigationFixtureState.betaPages;
    const emails: JmapEmail[] = [];
    if (this.label === 'Beta' && NavigationFixtureState.betaInboxSize !== null) {
      for (let index = NavigationFixtureState.betaInboxSize - 1; index >= 0; index--) {
        const mail = navigationMail('Beta', index, 0, true);
        mail.textBody = null; mail.keywords = index === 0 ? ['$seen'] : [];
        mail.receivedAt = 1789293600000 + index * 60000;
        emails.push(mail);
      }
      return { accountId, queryState: `Beta-${revision}`, emailState: `${revision}`, position: 0,
        nextPosition: null, total: emails.length, emails, notFound: [] };
    }
    for (let index = 0; index < 80; index++) { emails.push(navigationMail(this.label, index, revision)); }
    return { accountId, queryState: `${this.label}-${revision}`, emailState: `${revision}`, position: 0,
      nextPosition: null, total: emails.length, emails, notFound: [] };
  }
  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> {
    NavigationFixtureState.calls.push(`${this.label}:readEmail`);
    if (NavigationFixtureState.readerRecovery && this.label === 'Beta' && emailId === 'mail-00') {
      this.available(accountId);
      if (++NavigationFixtureState.readerAttempts === 1) { throw new JmapError('network'); }
      const mail = navigationMail('Beta', 0, 0, true);
      mail.subject = 'Old synthetic message'; mail.textBody = 'Recovered synthetic old message body';
      mail.receivedAt = 1704067200000;
      return mail;
    }
    return this.unexpected();
  }
  async createDraft(_accountId: string, _draft: JmapDraft): Promise<JmapCreatedDraft> { return this.unexpected(); }
  async setKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean): Promise<string> {
    NavigationFixtureState.calls.push(`${this.label}:setKeyword:${keyword}:${enabled}`);
    this.available(accountId);
    if (this.label !== 'Beta' || emailId !== 'mail-00' || (!enabled && !NavigationFixtureState.repeatKeywordActions) ||
      (keyword !== '$flagged' && keyword !== '$seen')) { return this.unexpected(); }
    await NavigationFixtureState.waitKeywordCompletion();
    return 'acknowledged';
  }
  async archiveEmail(_accountId: string, _emailId: string): Promise<JmapArchiveUndo> { return this.unexpected(); }
  async undoArchive(_undo: JmapArchiveUndo): Promise<void> { this.unexpected(); }
  private unexpected(): never {
    NavigationFixtureState.violations.push('Unexpected mail operation');
    throw new JmapError('unsupported');
  }
}
export class NavigationClientFactory implements JmapClientFactory {
  create(endpoint: string, _credentials: JmapCredentials): JmapService {
    const label = endpoint === 'https://alpha.example.test/session' ? 'Alpha' :
      endpoint === 'https://beta.example.test/session' ||
        (NavigationFixtureState.readerRecovery && endpoint === 'imaps://imap.gmail.com:993') ? 'Beta' : '';
    if (label === '') {
      NavigationFixtureState.violations.push('Unexpected endpoint');
      throw new JmapError('unsafeEndpoint');
    }
    NavigationFixtureState.created.push(label);
    return new NavigationClient(label);
  }
}
