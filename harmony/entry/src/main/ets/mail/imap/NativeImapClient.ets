// The existing presentation DTOs are shared with JMAP. IMAP encoding, sessions,
// trust, mailbox identity and MIME decoding live in Thunderbird's Swift core.
import { imapAccountRequest } from 'libthunderbird.so';
import { JmapService, JmapCredentials, JmapSession, JmapMailbox, JmapEmail, JmapEmailPage,
  JmapError, JmapKeyword, JmapArchiveUndo, JmapDraft, JmapCreatedDraft, MailAttachmentData } from '../jmap/JmapClient';

interface Request {
  operation: string; sessionUrl: string; authorization: string;
  accountId?: string; mailboxId?: string; position?: number; queryState?: string; emailId?: string; keyword?: string; enabled?: boolean;
  attachmentId?: string;
  username?: string;
  watchId?: string;
}
export interface ImapInboxCheck { state: string; mailboxId: string; newMessages: number; unreadEmails?: number; }
export interface ImapInboxWatch { supported: boolean; changed: boolean; }
interface Reply {
  session?: JmapSession; mailboxes?: JmapMailbox[]; page?: JmapEmailPage;
  email?: JmapEmail | null; error?: string; state?: string;
  attachment?: MailAttachmentData;
  inboxCheck?: ImapInboxCheck;
  inboxWatch?: ImapInboxWatch;
}
export class NativeImapClient implements JmapService {
  private readonly sessionUrl: string;
  private readonly credentials: JmapCredentials;
  private readonly username: string;
  private session: JmapSession | null = null;
  private watchRequests: Map<string, Request> = new Map();
  constructor(sessionUrl: string, credentials: JmapCredentials, username: string = '') {
    this.sessionUrl = sessionUrl; this.credentials = credentials; this.username = username;
  }
  private async request(input: Request): Promise<Reply> {
    if (this.username !== '') { input.username = this.username; }
    let reply: Reply;
    try { reply = JSON.parse(await imapAccountRequest(JSON.stringify(input))) as Reply; }
    catch (_) { throw new JmapError('network'); }
    if (reply.error !== undefined) { throw new JmapError(reply.error); }
    return reply;
  }
  async connect(): Promise<JmapSession> {
    if (this.session) { return this.session; }
    const reply = await this.request({ operation: 'connect', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization() });
    if (!reply.session) { throw new JmapError('invalidResponse'); }
    this.session = reply.session;
    return reply.session;
  }
  async mailboxes(accountId: string): Promise<JmapMailbox[]> {
    const reply = await this.request({ operation: 'mailboxes', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId });
    if (!reply.mailboxes) { throw new JmapError('invalidResponse'); }
    return reply.mailboxes;
  }
  async checkInbox(accountId: string, queryState?: string): Promise<ImapInboxCheck> {
    const reply = await this.request({ operation: 'checkInbox', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, queryState });
    const check = reply.inboxCheck;
    if (!check || typeof check.state !== 'string' || check.state.length === 0 ||
      typeof check.mailboxId !== 'string' || check.mailboxId.length === 0 ||
      !Number.isInteger(check.newMessages) || check.newMessages < 0 || check.newMessages > 50) {
      throw new JmapError('invalidResponse');
    }
    if (check.unreadEmails !== undefined && (!Number.isSafeInteger(check.unreadEmails) || check.unreadEmails < 0)) {
      throw new JmapError('invalidResponse');
    }
    return check;
  }
  async watchInbox(watchId: string): Promise<ImapInboxWatch> {
    let input = this.watchRequests.get(watchId);
    if (!input) {
      input = { operation: 'watchInbox', sessionUrl: this.sessionUrl, authorization: await this.credentials.authorization(),
        accountId: 'default', watchId: watchId };
      this.watchRequests.set(watchId, input);
    }
    try {
      const reply = await this.request(input), watch = reply.inboxWatch;
      if (!watch || typeof watch.supported !== 'boolean' || typeof watch.changed !== 'boolean') { throw new JmapError('invalidResponse'); }
      if (!watch.supported) { this.watchRequests.delete(watchId); }
      return watch;
    } catch (error) {
      this.watchRequests.delete(watchId); throw error as Error;
    }
  }
  async emailPage(accountId: string, mailboxId: string, position = 0, queryState?: string): Promise<JmapEmailPage> {
    const reply = await this.request({ operation: 'emailPage', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, mailboxId, position, queryState });
    if (!reply.page) { throw new JmapError('invalidResponse'); }
    return reply.page;
  }
  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> {
    const reply = await this.request({ operation: 'readEmail', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId });
    if (reply.email === undefined) { throw new JmapError('invalidResponse'); }
    return reply.email;
  }
  async createDraft(accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft> { throw new JmapError('unsupported'); }
  async readAttachment(accountId: string, emailId: string, attachmentId: string): Promise<MailAttachmentData> {
    const reply = await this.request({ operation: 'readAttachment', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId, attachmentId });
    if (!reply.attachment) { throw new JmapError('invalidResponse'); }
    return reply.attachment;
  }
  async setKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean): Promise<string> {
    const reply = await this.request({ operation: 'setKeyword', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId, keyword, enabled });
    if (!reply.state) { throw new JmapError('changeUnconfirmed'); }
    return reply.state;
  }
  async archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> { throw new JmapError('unsupported'); }
  async undoArchive(undo: JmapArchiveUndo): Promise<void> { throw new JmapError('unsupported'); }
}
export async function stopInboxWatch(watchId: string): Promise<void> {
  const reply = JSON.parse(await imapAccountRequest(JSON.stringify({ operation: 'stopInboxWatch',
    sessionUrl: '', authorization: '', watchId: watchId }))) as Reply;
  if (reply.error) { throw new JmapError(reply.error); }
  if (reply.state !== 'stopped') { throw new JmapError('invalidResponse'); }
}
