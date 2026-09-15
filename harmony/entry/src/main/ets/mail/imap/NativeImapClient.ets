// The existing presentation DTOs are shared with JMAP. IMAP encoding, sessions,
// trust, mailbox identity and MIME decoding live in Thunderbird's Swift core.
import { imapAccountRequest } from 'libthunderbird.so';
import { JmapService, JmapCredentials, JmapSession, JmapMailbox, JmapEmail, JmapEmailPage,
  JmapError, JmapKeyword, JmapArchiveUndo, validArchiveMailbox, JmapDraft, JmapCreatedDraft, MailAttachmentData } from '../jmap/JmapClient';

interface Request {
  operation: string; sessionUrl: string; authorization: string;
  accountId?: string; mailboxId?: string; position?: number; queryState?: string; emailId?: string; keyword?: string; enabled?: boolean;
  attachmentId?: string;
  username?: string;
  watchId?: string;
  syncSessionId?: string;
  previewKnownIds?: string[];
}
export interface ImapInboxCheck { state: string; mailboxId: string; newMessages: number; unreadEmails?: number; }
export interface ImapInboxWatch { supported: boolean; changed: boolean; }
interface Reply {
  session?: JmapSession; mailboxes?: JmapMailbox[]; page?: JmapEmailPage;
  email?: JmapEmail | null; error?: string; state?: string;
  attachment?: MailAttachmentData;
  inboxCheck?: ImapInboxCheck;
  inboxWatch?: ImapInboxWatch;
  archive?: JmapArchiveUndo;
  movedEmailId?: string;
}
interface SyncReadLease { closed: boolean; pending: number; }
export class NativeImapClient implements JmapService {
  private readonly sessionUrl: string;
  private readonly credentials: JmapCredentials;
  private readonly username: string;
  private session: JmapSession | null = null;
  private connecting: Promise<JmapSession> | null = null;
  private syncLeases: Map<string, SyncReadLease> = new Map();
  private watchRequests: Map<string, Request> = new Map();
  constructor(sessionUrl: string, credentials: JmapCredentials, username: string = '') {
    this.sessionUrl = sessionUrl; this.credentials = credentials; this.username = username;
  }
  private async request(input: Request): Promise<Reply> {
    if (this.username !== '' && input.operation !== 'closeSyncSession') { input.username = this.username; }
    let reply: Reply;
    try { reply = JSON.parse(await imapAccountRequest(JSON.stringify(input))) as Reply; }
    catch (_) { throw new JmapError('network'); }
    if (reply.error !== undefined) { throw new JmapError(reply.error); }
    return reply;
  }
  async connect(): Promise<JmapSession> {
    if (!this.session) {
      if (!this.connecting) { this.connecting = this.discover(); }
      try { this.session = await this.connecting; }
      finally { this.connecting = null; }
    }
    return JSON.parse(JSON.stringify(this.session)) as JmapSession;
  }
  private async discover(): Promise<JmapSession> {
    const reply = await this.request({ operation: 'connect', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization() });
    if (!reply.session) { throw new JmapError('invalidResponse'); }
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
  async emailPage(accountId: string, mailboxId: string, position = 0, queryState?: string, previewKnownIds?: string[]): Promise<JmapEmailPage> {
    // Opaque IMAP IDs include the mailbox name. A paginated cache can otherwise
    // make these optional hints exceed the bridge's 128 KiB request limit.
    // Reserve space for the credential envelope and required request fields.
    const hints: string[] = [];
    const seen: Set<string> = new Set();
    let remaining = 32 * 1024;
    for (const id of (previewKnownIds || []).slice(0, 500)) {
      if (id.length === 0 || id.length > 4096 || !/^[A-Za-z0-9_-]+$/.test(id) || seen.has(id)) { continue; }
      const bytes = id.length + 3;
      if (bytes > remaining) { continue; }
      hints.push(id); seen.add(id); remaining -= bytes;
    }
    const reply = await this.request({ operation: 'emailPage', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, mailboxId, position, queryState,
      previewKnownIds: hints.length > 0 ? hints : undefined });
    if (!reply.page) { throw new JmapError('invalidResponse'); }
    return reply.page;
  }
  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> {
    const reply = await this.request({ operation: 'readEmail', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId });
    if (reply.email === undefined) { throw new JmapError('invalidResponse'); }
    return reply.email;
  }
  async readEmailForSync(accountId: string, emailId: string, syncSessionId: string): Promise<JmapEmail | null> {
    let lease = this.syncLeases.get(syncSessionId);
    if (!lease) { lease = { closed: false, pending: 0 }; this.syncLeases.set(syncSessionId, lease); }
    if (lease.closed) { throw new JmapError('network'); }
    ++lease.pending;
    try {
      // Refresh credentials normally; a reused native connection remains bound
      // to the exact current authorization, endpoint and login.
      const authorization = await this.credentials.authorization();
      if (lease.closed) { throw new JmapError('network'); }
      const reply = await this.request({ operation: 'readEmail', sessionUrl: this.sessionUrl,
        authorization, accountId, emailId, syncSessionId });
      if (reply.email === undefined) { throw new JmapError('invalidResponse'); }
      return reply.email;
    } finally {
      --lease.pending;
      if (lease.closed && lease.pending === 0 && this.syncLeases.get(syncSessionId) === lease) {
        this.syncLeases.delete(syncSessionId);
      }
    }
  }
  async closeSyncSession(syncSessionId: string): Promise<void> {
    const lease = this.syncLeases.get(syncSessionId);
    if (lease) { lease.closed = true; if (lease.pending === 0) { this.syncLeases.delete(syncSessionId); } }
    const reply = await this.request({ operation: 'closeSyncSession', sessionUrl: '', authorization: '', syncSessionId });
    if (reply.state !== 'closed') { throw new JmapError('invalidResponse'); }
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
  async archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    return this.moveEmail(accountId, emailId, false);
  }
  async deleteEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    return this.moveEmail(accountId, emailId, true);
  }
  private async moveEmail(accountId: string, emailId: string, deleting: boolean): Promise<JmapArchiveUndo> {
    const reply = await this.request({ operation: deleting ? 'deleteEmail' : 'archiveEmail', sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId });
    const undo = reply.archive;
    if (!undo || (deleting ? undo.action !== 'delete' : undo.action !== undefined && undo.action !== 'archive') || undo.accountId !== accountId || undo.emailId !== emailId || undo.imap !== true ||
      typeof undo.inboxId !== 'string' || !undo.inboxId || typeof undo.archiveId !== 'string' || !undo.archiveId ||
      !Array.isArray(undo.expectedMailboxIds) || undo.expectedMailboxIds.length !== 1 ||
      undo.expectedMailboxIds[0] !== undo.archiveId || undo.archiveId === undo.inboxId || typeof undo.canUndo !== 'boolean' ||
      (undo.movedEmailId !== undefined && (typeof undo.movedEmailId !== 'string' || !undo.movedEmailId || undo.movedEmailId === emailId)) ||
      (undo.canUndo && !undo.movedEmailId) ||
      (undo.archiveMailbox !== undefined && !validArchiveMailbox(undo.archiveMailbox, undo.archiveId, deleting ? 'trash' : 'archive'))) {
      throw new JmapError('changeUnconfirmed');
    }
    return undo;
  }
  async undoArchive(undo: JmapArchiveUndo): Promise<string | void> {
    if (undo.imap !== true || undo.canUndo === false) { throw new JmapError('archiveUnavailable'); }
    // Snapshot ownership before the credential lookup can yield to navigation.
    const accountId = undo.accountId, emailId = undo.emailId, mailboxId = undo.inboxId;
    const operation = undo.action === 'delete' ? 'undoDelete' : 'undoArchive';
    const reply = await this.request({ operation, sessionUrl: this.sessionUrl,
      authorization: await this.credentials.authorization(), accountId, emailId, mailboxId });
    if (reply.state !== 'moved' || (reply.movedEmailId !== undefined &&
      (typeof reply.movedEmailId !== 'string' || !reply.movedEmailId))) { throw new JmapError('changeUnconfirmed'); }
    return reply.movedEmailId;
  }
}
export async function stopInboxWatch(watchId: string): Promise<void> {
  const reply = JSON.parse(await imapAccountRequest(JSON.stringify({ operation: 'stopInboxWatch',
    sessionUrl: '', authorization: '', watchId: watchId }))) as Reply;
  if (reply.error) { throw new JmapError(reply.error); }
  if (reply.state !== 'stopped') { throw new JmapError('invalidResponse'); }
}
