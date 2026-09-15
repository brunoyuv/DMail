// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/

export interface ParsedEndpoint {
  href: string;
  origin: string;
  protocol: string;
  username: string;
  password: string;
  hash: string;
}

// Platform URL parsing plus the mandatory original Swift core. There is no HTTP
// send hook or alternate protocol engine in the shipping client.
export interface JmapTransport {
  readonly accountCore: JmapAccountCore;
  parseUrl(value: string, base?: string): ParsedEndpoint;
}

export interface JmapCredentials {
  readonly username?: string;
  authorization(): Promise<string>;
}

export class JmapError extends Error {
  constructor(public readonly code: string, public readonly status: number = 0) {
    // Never include server descriptions, URLs, tokens or mail contents in errors.
    super(`JMAP: ${code}`);
    this.name = 'JmapError';
  }
}

export interface JmapAccount {
  id: string;
  name: string;
  isPersonal: boolean;
  isReadOnly: boolean;
}

export interface JmapSession {
  apiUrl: string;
  state: string;
  accounts: JmapAccount[];
  primaryAccountId: string | null;
  maxObjectsInGet: number;
}

export interface JmapConnection { session: JmapSession; maxRequestBytes: number; }
export interface JmapAccountCore {
  connect(sessionUrl: string, authorization: string): Promise<JmapConnection>;
  mailboxes(sessionUrl: string, authorization: string, accountId: string): Promise<JmapMailbox[]>;
  emailPage(sessionUrl: string, authorization: string, accountId: string, mailboxId: string,
    position: number, queryState?: string): Promise<JmapEmailPage>;
  getEmails(sessionUrl: string, authorization: string, accountId: string, emailIds: string[],
    includeBody: boolean): Promise<JmapEmailSnapshot>;
  setKeyword(sessionUrl: string, authorization: string, accountId: string, emailId: string,
    keyword: JmapKeyword, enabled: boolean): Promise<string>;
  archiveEmail(sessionUrl: string, authorization: string, accountId: string, emailId: string): Promise<JmapArchiveUndo>;
  undoArchive(sessionUrl: string, authorization: string, undo: JmapArchiveUndo): Promise<void>;
  createDraft(sessionUrl: string, authorization: string, accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft>;
}

export interface JmapEmailSnapshot { emails: JmapEmail[]; notFound: string[]; state: string; }

export interface JmapMailbox {
  id: string;
  name: string;
  parentId: string | null;
  role: string | null;
  sortOrder: number;
  totalEmails: number;
  unreadEmails: number;
  countsKnown?: boolean;
  // A native Inbox may offer explicit first-use creation; this is not a listed folder.
  archiveDestinationId?: string;
  archiveDestinationName?: string;
  maySetSeen: boolean;
  maySetKeywords: boolean;
  mayAddItems: boolean;
  mayRemoveItems: boolean;
}

export interface JmapArchiveUndo {
  accountId: string;
  emailId: string;
  inboxId: string;
  archiveId: string;
  addedArchive: boolean;
  expectedMailboxIds: string[];
  // IMAP UID MOVE changes the protocol identity. Missing COPYUID cannot enable Undo.
  movedEmailId?: string;
  canUndo?: boolean;
  imap?: boolean;
  archiveMailbox?: JmapMailbox;
  action?: string;
}

export function validArchiveDestinationHint(box: JmapMailbox): boolean {
  if (box.archiveDestinationId === undefined && box.archiveDestinationName === undefined) { return true; }
  return box.role === 'inbox' && typeof box.archiveDestinationId === 'string' &&
    /^[A-Za-z0-9_-]{1,4096}$/.test(box.archiveDestinationId) && box.archiveDestinationId !== box.id &&
    typeof box.archiveDestinationName === 'string' && box.archiveDestinationName.length > 0 &&
    box.archiveDestinationName.length <= 1024 && !/[\x00-\x1f\x7f]/.test(box.archiveDestinationName);
}
export function validArchiveMailbox(box: JmapMailbox, archiveId: string, role: string = 'archive'): boolean {
  return !!box && typeof box === 'object' && !Array.isArray(box) &&
    box.id === archiveId && /^[A-Za-z0-9_-]{1,4096}$/.test(box.id) && box.role === role &&
    typeof box.name === 'string' && box.name.length > 0 && box.name.length <= 1024 && !/[\x00-\x1f\x7f]/.test(box.name) &&
    (box.parentId === null || (typeof box.parentId === 'string' && /^[A-Za-z0-9_-]{1,4096}$/.test(box.parentId))) &&
    Number.isSafeInteger(box.sortOrder) && box.sortOrder >= 0 &&
    Number.isSafeInteger(box.totalEmails) && box.totalEmails >= 0 &&
    Number.isSafeInteger(box.unreadEmails) && box.unreadEmails >= 0 &&
    (box.countsKnown === undefined || typeof box.countsKnown === 'boolean') &&
    typeof box.maySetSeen === 'boolean' && typeof box.maySetKeywords === 'boolean' &&
    typeof box.mayAddItems === 'boolean' && typeof box.mayRemoveItems === 'boolean' && validArchiveDestinationHint(box);
}

export function archiveTarget(mail: JmapEmail, boxes: JmapMailbox[]): JmapMailbox | null {
  if (mail.id.startsWith('local_')) { return null; }
  const inboxes = boxes.filter((box) => box.role === 'inbox');
  const archives = boxes.filter((box) => box.role === 'archive');
  if (inboxes.length !== 1 || archives.length > 1) { return null; }
  const inbox = inboxes[0];
  let archive = archives[0];
  if (!archive) {
    if (!validArchiveDestinationHint(inbox) || !inbox.archiveDestinationId || !inbox.archiveDestinationName) { return null; }
    archive = { ...inbox, id: inbox.archiveDestinationId, name: inbox.archiveDestinationName,
      parentId: null, role: 'archive', sortOrder: 2, totalEmails: 0, unreadEmails: 0, countsKnown: false,
      mayAddItems: true, archiveDestinationId: undefined, archiveDestinationName: undefined };
  }
  return inbox.id !== archive.id && mail.mailboxIds.includes(inbox.id) && inbox.mayRemoveItems &&
    (mail.mailboxIds.includes(archive.id) || archive.mayAddItems) ? archive : null;
}

export function trashTarget(mail: JmapEmail, boxes: JmapMailbox[]): JmapMailbox | null {
  if (mail.id.startsWith('local_')) { return null; }
  const inboxes = boxes.filter(box => box.role === 'inbox');
  const trash = boxes.filter(box => box.role === 'trash');
  if (inboxes.length !== 1 || trash.length !== 1) { return null; }
  return inboxes[0].id !== trash[0].id && mail.mailboxIds.includes(inboxes[0].id) &&
    inboxes[0].mayRemoveItems && trash[0].mayAddItems ? trash[0] : null;
}

export type JmapKeyword = '$seen' | '$flagged';

// A message can belong to several mailboxes. RFC 8621 requires this right
// in every mailbox, including labels, before its keywords may be changed.
export function canSetKeyword(mail: JmapEmail, boxes: JmapMailbox[], keyword: JmapKeyword): boolean {
  // IMAP permissions describe the UID's selected mailbox and are rechecked
  // natively before STORE. JMAP continues to require rights in every mailbox.
  if (mail.maySetSeen !== undefined && mail.maySetKeywords !== undefined) {
    return mail.mailboxIds.length === 1 && (keyword === '$seen' ? mail.maySetSeen === true : mail.maySetKeywords === true);
  }
  return mail.mailboxIds.length > 0 && mail.mailboxIds.every((mailboxId) => {
    const box = boxes.find((entry) => entry.id === mailboxId);
    return box !== undefined && (keyword === '$seen' ? box.maySetSeen : box.maySetKeywords);
  });
}

export interface JmapAddress { name: string; email: string; }

export interface JmapDraft {
  from: JmapAddress | null;
  to: JmapAddress[];
  cc: JmapAddress[];
  bcc: JmapAddress[];
  replyTo: JmapAddress[];
  subject: string;
  textBody: string;
  inReplyTo: string[];
  references: string[];
}

export interface JmapCreatedDraft {
  id: string;
  blobId: string;
  threadId: string;
  size: number;
  state: string;
  mailboxId: string;
}

// Creation IDs correlate a single request; they are not idempotency keys.
// A caller must retain its local draft and reconcile an uncertain outcome
// before offering another upload, even if the failure looks transient.
export class JmapDraftError extends JmapError {
  constructor(code: string, public readonly mayHaveCreated: boolean, status: number = 0) {
    super(code, status);
    this.name = 'JmapDraftError';
  }
}

// Keep server IDs, multi-mailbox membership and MIME body status intact.
// The offline preview's single Folder field is deliberately not used here.
export interface MailAttachment {
  id: string; name: string; contentType: string; size: number; sizeIsEncoded: boolean;
}
export interface MailAttachmentData { name: string; contentType: string; base64: string; }
export interface JmapEmail {
  // Local header-only cache projection, for choosing conversation copies.
  // It does not make a bodyless record safe to display as a downloaded body.
  cachedBodyAvailable?: boolean;
  // Local immutable content/cache origin across a verified IMAP UID MOVE.
  cachedSourceId?: string;
  // Account-local attachment cache origins after confirmed UID moves (at most 16).
  cachedAttachmentSourceIds?: string[];
  attachments?: MailAttachment[];
  cc?: JmapAddress[];
  inReplyTo?: string[];
  references?: string[];
  id: string;
  threadId: string;
  messageIds: string[];
  mailboxIds: string[];
  keywords: string[];
  from: JmapAddress[];
  to: JmapAddress[];
  replyTo: JmapAddress[];
  subject: string;
  preview: string;
  receivedAt: number;
  hasAttachment: boolean;
  htmlBody?: string | null;
  textBody: string | null;
  bodyTruncated: boolean;
  bodyEncodingProblem: boolean;
  hasHtmlBody: boolean;
  maySetSeen?: boolean;
  maySetKeywords?: boolean;
}

// ArkTS callers can share immutable body strings without JSON round-tripping.
// Replace an array before mutating it; this intentionally copies only the record.
export function shallowCopyEmail(mail: JmapEmail): JmapEmail { return { ...mail }; }

export interface JmapEmailPage {
  accountId: string;
  queryState: string;
  emailState: string | null;
  position: number;
  nextPosition: number | null;
  total: number | null;
  emails: JmapEmail[];
  notFound: string[];
}

export interface JmapService {
  // Optional bounded connection reuse for background body preparation only.
  readEmailForSync?(accountId: string, emailId: string, syncSessionId: string): Promise<JmapEmail | null>;
  closeSyncSession?(syncSessionId: string): Promise<void>;
  readAttachment?(accountId: string, emailId: string, attachmentId: string): Promise<MailAttachmentData>;
  connect(): Promise<JmapSession>;
  mailboxes(accountId: string): Promise<JmapMailbox[]>;
  emailPage(accountId: string, mailboxId: string, position?: number, queryState?: string, previewKnownIds?: string[]): Promise<JmapEmailPage>;
  readEmail(accountId: string, emailId: string): Promise<JmapEmail | null>;
  createDraft(accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft>;
  setKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean): Promise<string>;
  archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo>;
  deleteEmail?(accountId: string, emailId: string): Promise<JmapArchiveUndo>;
  undoArchive(undo: JmapArchiveUndo): Promise<string | void>;
}

export interface JmapClientFactory {
  create(sessionUrl: string, credentials: JmapCredentials): JmapService;
}

// HarmonyOS UI facade. Wire encoding, transport, validation and mail operations
// belong to Thunderbird's Swift module and its explicit port patches.
export class JmapClient implements JmapService {
  private session: JmapSession | null = null;
  private connecting: Promise<JmapSession> | null = null;
  private readonly sessionUrl: string;
  private readonly core: JmapAccountCore;

  constructor(sessionUrl: string, platform: JmapTransport, private readonly credentials: JmapCredentials) {
    if (!platform.accountCore) { throw new JmapError('nativeCoreUnavailable'); }
    this.core = platform.accountCore;
    try {
      const parsed = platform.parseUrl(sessionUrl);
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.hash ||
        /[\u0000-\u0020\u007f\\]/.test(sessionUrl)) { throw new Error(); }
      this.sessionUrl = parsed.href;
    } catch (_) { throw new JmapError('unsafeEndpoint'); }
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
    return (await this.core.connect(this.sessionUrl, await this.credentials.authorization())).session;
  }

  async mailboxes(accountId: string): Promise<JmapMailbox[]> {
    return this.core.mailboxes(this.sessionUrl, await this.credentials.authorization(), accountId);
  }

  async emailPage(accountId: string, mailboxId: string, position = 0, queryState?: string): Promise<JmapEmailPage> {
    return this.core.emailPage(this.sessionUrl, await this.credentials.authorization(), accountId, mailboxId, position, queryState);
  }

  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> {
    const result = await this.core.getEmails(this.sessionUrl, await this.credentials.authorization(), accountId, [emailId], true);
    return result.emails[0] ?? null;
  }

  async createDraft(accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft> {
    // Capture edits before waiting for credential storage. Never retry a create.
    let snapshot: JmapDraft;
    try { snapshot = JSON.parse(JSON.stringify(draft)) as JmapDraft; }
    catch (_) { throw new JmapError('invalidDraft'); }
    return this.core.createDraft(this.sessionUrl, await this.credentials.authorization(), accountId, snapshot);
  }

  async setKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean): Promise<string> {
    return this.core.setKeyword(this.sessionUrl, await this.credentials.authorization(), accountId, emailId, keyword, enabled);
  }

  async archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    return this.core.archiveEmail(this.sessionUrl, await this.credentials.authorization(), accountId, emailId);
  }

  async undoArchive(undo: JmapArchiveUndo): Promise<void> {
    // The user may navigate or alter state while credentials are being read.
    const snapshot = JSON.parse(JSON.stringify(undo)) as JmapArchiveUndo;
    return this.core.undoArchive(this.sessionUrl, await this.credentials.authorization(), snapshot);
  }
}
