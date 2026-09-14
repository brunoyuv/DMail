// MPL-2.0: https://mozilla.org/MPL/2.0/
// Historical ArkTS protocol prototype. Test-only; never imported by the shipping app.
import { ParsedEndpoint, JmapCredentials, JmapError, JmapAccount, JmapSession, JmapConnection, JmapAccountCore, JmapEmailSnapshot, JmapMailbox, JmapArchiveUndo, archiveTarget, JmapKeyword, canSetKeyword, JmapAddress, JmapDraft, JmapCreatedDraft, JmapDraftError, JmapEmail, JmapEmailPage } from '../../../main/ets/mail/jmap/JmapClient';
export { ParsedEndpoint, JmapCredentials, JmapError, JmapAccount, JmapSession, JmapConnection, JmapAccountCore, JmapEmailSnapshot, JmapMailbox, JmapArchiveUndo, archiveTarget, JmapKeyword, canSetKeyword, JmapAddress, JmapDraft, JmapCreatedDraft, JmapDraftError, JmapEmail, JmapEmailPage } from '../../../main/ets/mail/jmap/JmapClient';

export const JMAP_CORE = 'urn:ietf:params:jmap:core';
export const JMAP_MAIL = 'urn:ietf:params:jmap:mail';
export const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

export interface JmapHttpRequest {
  url: string;
  method: 'GET' | 'POST';
  headers: Record<string, string>;
  body?: string;
  maxResponseBytes: number;
}

export interface JmapHttpResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

// Implementations must verify TLS, disable automatic redirects, enforce the byte
// limit while receiving, and avoid logging headers or response bodies.
export interface JmapTransport {
  parseUrl(value: string, base?: string): ParsedEndpoint;
  send(request: JmapHttpRequest): Promise<JmapHttpResponse>;
}

type JsonObject = Record<string, unknown>;

function utf8Size(value: string): number {
  let size = 0;
  for (const character of value) {
    const point = character.codePointAt(0)!;
    size += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
  }
  return size;
}

function draftContent(draft: JmapDraft): JsonObject {
  function header(value: string): string {
    if (typeof value !== 'string' || /[\u0000-\u001f\u007f]/.test(value)) { throw new JmapError('invalidDraft'); }
    return value;
  }
  function address(value: JmapAddress): JmapAddress {
    if (!value || typeof value !== 'object') { throw new JmapError('invalidDraft'); }
    return { name: header(value.name), email: header(value.email) };
  }
  function addressList(value: JmapAddress[]): JmapAddress[] | null {
    if (!Array.isArray(value)) { throw new JmapError('invalidDraft'); }
    return value.length === 0 ? null : value.map(address);
  }
  function messageIds(value: string[]): string[] | null {
    if (!Array.isArray(value) || value.some(entry => typeof entry !== 'string' || !entry || /[\s<>]/.test(entry))) {
      throw new JmapError('invalidDraft');
    }
    return value.length === 0 ? null : value.map(header);
  }
  if (!draft || typeof draft !== 'object' || typeof draft.textBody !== 'string' || draft.textBody.includes('\u0000')) {
    throw new JmapError('invalidDraft');
  }
  if (utf8Size(draft.textBody) > 256 * 1024) { throw new JmapError('draftTooLarge'); }
  // Draft recipients may be incomplete. Strict delivery validation belongs to
  // submission; never silently discard unfinished addresses while saving.
  return { from: draft.from === null ? null : [address(draft.from)], to: addressList(draft.to),
    cc: addressList(draft.cc), bcc: addressList(draft.bcc), replyTo: addressList(draft.replyTo),
    subject: header(draft.subject), inReplyTo: messageIds(draft.inReplyTo), references: messageIds(draft.references),
    textBody: [{ partId: 'body', type: 'text/plain' }],
    bodyValues: { body: { value: draft.textBody, isTruncated: false, isEncodingProblem: false } } };
}

function object(value: unknown): JsonObject {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new JmapError('invalidResponse');
  }
  return value as JsonObject;
}

function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) { throw new JmapError('invalidResponse'); }
  return value;
}

function string(value: unknown): string {
  if (typeof value !== 'string') { throw new JmapError('invalidResponse'); }
  return value;
}

function id(value: unknown): string {
  const result = string(value);
  if (!/^[A-Za-z0-9_-]{1,255}$/.test(result)) { throw new JmapError('invalidResponse'); }
  return result;
}

function uint(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw new JmapError('invalidResponse');
  }
  return value;
}

function bool(value: unknown): boolean {
  if (typeof value !== 'boolean') { throw new JmapError('invalidResponse'); }
  return value;
}

function ids(value: unknown): string[] {
  const result = array(value).map(id);
  if (new Set(result).size !== result.length) { throw new JmapError('invalidResponse'); }
  return result;
}

function nullableString(value: unknown): string | null {
  return value === null ? null : string(value);
}

function addresses(value: unknown): JmapAddress[] {
  return value === null ? [] : array(value).map((entry) => {
    const address = object(entry);
    return { name: address.name === null ? '' : string(address.name), email: string(address.email) };
  });
}

function trueKeys(value: unknown): string[] {
  const map = object(value);
  const keys = Object.keys(map);
  if (keys.some((key) => map[key] !== true)) { throw new JmapError('invalidResponse'); }
  return keys;
}

function email(value: unknown, includeBody: boolean): JmapEmail {
  const raw = object(value);
  const timestamp = string(raw.receivedAt);
  const receivedAt = Date.parse(timestamp);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(timestamp) || !Number.isFinite(receivedAt) ||
    new Date(receivedAt).toISOString().slice(0, 19) !== timestamp.slice(0, 19)) {
    throw new JmapError('invalidResponse');
  }
  let textBody: string | null = null;
  let bodyTruncated = false;
  let bodyEncodingProblem = false;
  let hasHtmlBody = false;
  if (includeBody) {
    const parts = array(raw.textBody).map(object);
    hasHtmlBody = array(raw.htmlBody).length > 0;
    const values = object(raw.bodyValues);
    const text: string[] = [];
    for (const part of parts) {
      if (string(part.type).toLowerCase() !== 'text/plain') { continue; }
      const body = object(values[string(part.partId)]);
      text.push(string(body.value));
      bodyTruncated = bool(body.isTruncated) || bodyTruncated;
      bodyEncodingProblem = bool(body.isEncodingProblem) || bodyEncodingProblem;
    }
    if (text.length > 0) { textBody = text.join('\n\n'); }
  }
  return {
    id: id(raw.id), threadId: id(raw.threadId),
    messageIds: raw.messageId === null ? [] : array(raw.messageId).map(string),
    mailboxIds: trueKeys(raw.mailboxIds).map(id), keywords: trueKeys(raw.keywords),
    from: addresses(raw.from), to: addresses(raw.to), replyTo: addresses(raw.replyTo),
    subject: string(raw.subject), preview: string(raw.preview), receivedAt,
    hasAttachment: bool(raw.hasAttachment), textBody, bodyTruncated, bodyEncodingProblem, hasHtmlBody
  };
}

const SUMMARY_PROPERTIES = [
  'id', 'threadId', 'messageId', 'mailboxIds', 'keywords', 'from', 'to', 'replyTo',
  'subject', 'preview', 'receivedAt', 'hasAttachment'
];

export class JmapClient {
  private session: JmapSession | null = null;
  private connecting: Promise<JmapSession> | null = null;
  private callNumber = 0;
  private maxRequestBytes = 4 * 1024 * 1024;
  private readonly sessionUrl: string;
  private readonly origin: string;

  constructor(
    sessionUrl: string,
    private readonly transport: JmapTransport,
    private readonly credentials: JmapCredentials
  ) {
    const endpoint = this.endpoint(sessionUrl);
    this.sessionUrl = endpoint.href;
    this.origin = endpoint.origin;
  }

  private endpoint(value: string, base?: string): ParsedEndpoint {
    try {
      const parsed = this.transport.parseUrl(value, base);
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.hash ||
        /[\u0000-\u0020\u007f\\]/.test(value)) { throw new Error(); }
      return parsed;
    } catch (_) { throw new JmapError('unsafeEndpoint'); }
  }

  async connect(): Promise<JmapSession> {
    if (!this.session) {
      if (!this.connecting) { this.connecting = this.discover(); }
      try { this.session = await this.connecting; }
      finally { this.connecting = null; }
    }
    // Consumers cannot mutate the client's selected accounts or endpoint.
    return JSON.parse(JSON.stringify(this.session)) as JmapSession;
  }

  private async discover(): Promise<JmapSession> {
    const raw = await this.exchange(this.sessionUrl, 'GET');
    const capabilities = object(raw.capabilities);
    const core = object(capabilities[JMAP_CORE]);
    object(capabilities[JMAP_MAIL]);
    const maxObjectsInGet = uint(core.maxObjectsInGet);
    if (maxObjectsInGet === 0) { throw new JmapError('invalidResponse'); }
    const maxSizeRequest = core.maxSizeRequest === undefined ? this.maxRequestBytes : uint(core.maxSizeRequest);
    if (maxSizeRequest === 0) { throw new JmapError('invalidResponse'); }
    const api = this.endpoint(string(raw.apiUrl));
    // Cross-origin service URLs require a future explicit trust decision in
    // account setup. Never forward a user's credential to an arbitrary origin.
    if (api.origin !== this.origin) { throw new JmapError('untrustedApiOrigin'); }
    const accountMap = object(raw.accounts);
    const accounts: JmapAccount[] = [];
    for (const accountId of Object.keys(accountMap)) {
      const account = object(accountMap[accountId]);
      const accountCapabilities = object(account.accountCapabilities);
      if (Object.prototype.hasOwnProperty.call(accountCapabilities, JMAP_MAIL)) {
        object(accountCapabilities[JMAP_MAIL]);
        accounts.push({ id: id(accountId), name: string(account.name),
          isPersonal: bool(account.isPersonal), isReadOnly: bool(account.isReadOnly) });
      }
    }
    if (accounts.length === 0) { throw new JmapError('mailNotSupported'); }
    const primary = object(raw.primaryAccounts)[JMAP_MAIL];
    const primaryAccountId = primary === null || primary === undefined ? null : id(primary);
    if (primaryAccountId !== null && !accounts.some((account) => account.id === primaryAccountId)) {
      throw new JmapError('invalidResponse');
    }
    const state = string(raw.state);
    this.maxRequestBytes = Math.min(maxSizeRequest, 4 * 1024 * 1024);
    return { apiUrl: api.href, state, accounts, primaryAccountId, maxObjectsInGet };
  }

  private async exchange(url: string, method: 'GET' | 'POST', body?: string): Promise<JsonObject> {
    for (let redirect = 0; redirect <= 3; redirect++) {
      let response: JmapHttpResponse;
      try {
        const authorization = await this.credentials.authorization();
        if (!/^(Bearer|Basic) [A-Za-z0-9._~+\/-]+=*$/.test(authorization)) {
          throw new JmapError('authenticationRequired');
        }
        response = await this.transport.send({ url, method, body, maxResponseBytes: MAX_RESPONSE_BYTES,
          headers: { Authorization: authorization, Accept: 'application/json',
            'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
      } catch (error) {
        if (error instanceof JmapError) { throw error; }
        throw new JmapError('network');
      }
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        // Follow discovery redirects only. API POSTs are never replayed.
        if (method !== 'GET' || redirect === 3) { throw new JmapError('redirectRejected'); }
        const location = Object.keys(response.headers).find((key) => key.toLowerCase() === 'location');
        if (!location) { throw new JmapError('invalidResponse'); }
        const target = this.endpoint(response.headers[location], url);
        if (target.origin !== this.origin) { throw new JmapError('redirectRejected'); }
        url = target.href;
        continue;
      }
      if (response.status === 401 || response.status === 403) {
        throw new JmapError('authenticationRequired', response.status);
      }
      if (response.status === 429) { throw new JmapError('rateLimited', response.status); }
      if (response.status !== 200) { throw new JmapError('http', response.status); }
      if (response.body.length > MAX_RESPONSE_BYTES) { throw new JmapError('responseTooLarge'); }
      const contentType = Object.keys(response.headers).find((key) => key.toLowerCase() === 'content-type');
      if (!contentType || response.headers[contentType].split(';')[0].trim().toLowerCase() !== 'application/json') {
        throw new JmapError('invalidResponse');
      }
      try { return object(JSON.parse(response.body)); }
      catch (_) { throw new JmapError('invalidResponse'); }
    }
    throw new JmapError('redirectRejected');
  }

  private async call(name: string, accountId: string, args: JsonObject): Promise<JsonObject> {
    const session = await this.connect();
    if (!session.accounts.some((account) => account.id === accountId)) { throw new JmapError('accountNotFound'); }
    const callId = `c${++this.callNumber}`;
    const body = JSON.stringify({
      using: [JMAP_CORE, JMAP_MAIL], methodCalls: [[name, { ...args, accountId }, callId]]
    });
    if (utf8Size(body) > this.maxRequestBytes) { throw new JmapError('requestTooLarge'); }
    const result = await this.exchange(session.apiUrl, 'POST', body);
    string(result.sessionState);
    const calls = array(result.methodResponses).map(array);
    const matches = calls.filter((entry) => entry.length === 3 && entry[2] === callId);
    if (matches.length !== 1) { throw new JmapError('invalidResponse'); }
    const invocation = matches[0];
    const response = object(invocation[1]);
    if (invocation[0] === 'error') {
      const type = string(response.type);
      // Keep the server-provided type out of the message and diagnostics.
      if (type === 'accountNotFound') { throw new JmapError('accountNotFound'); }
      if (type === 'accountReadOnly') { throw new JmapError('accountReadOnly'); }
      if (type === 'stateMismatch') { throw new JmapError('stateMismatch'); }
      if (type === 'tooManyObjects') { throw new JmapError('tooManyObjects'); }
      throw new JmapError('methodFailed');
    }
    if (invocation[0] !== name || response.accountId !== accountId) { throw new JmapError('invalidResponse'); }
    return response;
  }

  async mailboxes(accountId: string): Promise<JmapMailbox[]> {
    const raw = await this.call('Mailbox/get', accountId, { ids: null,
      properties: ['id', 'name', 'parentId', 'role', 'sortOrder', 'totalEmails', 'unreadEmails', 'myRights'] });
    string(raw.state);
    if (ids(raw.notFound).length !== 0) { throw new JmapError('invalidResponse'); }
    const result = array(raw.list).map((value) => {
      const mailbox = object(value);
      const rights = object(mailbox.myRights);
      return { id: id(mailbox.id), name: string(mailbox.name), parentId: nullableString(mailbox.parentId),
        role: nullableString(mailbox.role), sortOrder: uint(mailbox.sortOrder),
        totalEmails: uint(mailbox.totalEmails), unreadEmails: uint(mailbox.unreadEmails),
        maySetSeen: bool(rights.maySetSeen), maySetKeywords: bool(rights.maySetKeywords),
        mayAddItems: bool(rights.mayAddItems), mayRemoveItems: bool(rights.mayRemoveItems) };
    });
    ids(result.map((mailbox) => mailbox.id));
    return result;
  }

  async emailPage(accountId: string, mailboxId: string, position = 0, queryState?: string): Promise<JmapEmailPage> {
    const session = await this.connect();
    id(mailboxId); uint(position);
    const limit = Math.min(session.maxObjectsInGet, 50);
    const query = await this.call('Email/query', accountId, { filter: { inMailbox: mailboxId },
      sort: [{ property: 'receivedAt', isAscending: false }], position, limit, calculateTotal: true });
    const state = string(query.queryState);
    if (queryState !== undefined && queryState !== state) { throw new JmapError('queryChanged'); }
    const queryPosition = uint(query.position);
    if (queryPosition !== position) { throw new JmapError('queryChanged'); }
    const emailIds = ids(query.ids);
    if (emailIds.length > limit) { throw new JmapError('invalidResponse'); }
    const total = query.total === undefined ? null : uint(query.total);
    if (total !== null && ((emailIds.length > 0 && total < position + emailIds.length) ||
      (emailIds.length === 0 && position < total))) {
      throw new JmapError('invalidResponse');
    }
    const nextPosition = emailIds.length === 0 || total === position + emailIds.length ? null : position + emailIds.length;
    if (emailIds.length === 0) {
      return { accountId, queryState: state, emailState: null, position, nextPosition, total, emails: [], notFound: [] };
    }
    const result = await this.getEmails(accountId, emailIds, false);
    return { accountId, queryState: state, emailState: result.state, position, nextPosition, total,
      emails: result.emails, notFound: result.notFound };
  }

  async readEmail(accountId: string, emailId: string): Promise<JmapEmail | null> {
    const result = await this.getEmails(accountId, [id(emailId)], true);
    return result.emails[0] ?? null;
  }

  async createDraft(accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft> {
    // Copy/validate before the first await: editing the composer during a save
    // must not change which version is actually uploaded.
    const content = draftContent(draft);
    const session = await this.connect();
    const account = session.accounts.find(entry => entry.id === accountId);
    if (!account) { throw new JmapError('accountNotFound'); }
    if (account.isReadOnly) { throw new JmapError('accountReadOnly'); }
    const drafts = (await this.mailboxes(accountId)).filter(box => box.role === 'drafts');
    if (drafts.length !== 1) { throw new JmapError('draftsUnavailable'); }
    const mailbox = drafts[0];
    if (!mailbox.mayAddItems) { throw new JmapError('forbidden'); }
    try {
      const raw = await this.call('Email/set', accountId, { create: { draft: {
        ...content, mailboxIds: { [mailbox.id]: true }, keywords: { $draft: true, $seen: true }
      } } });
      nullableString(raw.oldState);
      const state = string(raw.newState);
      const created = raw.created === null || raw.created === undefined ? {} : object(raw.created);
      const rejected = raw.notCreated === null || raw.notCreated === undefined ? {} : object(raw.notCreated);
      const reported = Object.keys(created).concat(Object.keys(rejected));
      if (reported.length !== 1 || reported[0] !== 'draft') { throw new JmapError('invalidResponse'); }
      for (const key of ['updated', 'notUpdated', 'notDestroyed']) {
        if (raw[key] !== null && raw[key] !== undefined && Object.keys(object(raw[key])).length !== 0) {
          throw new JmapError('invalidResponse');
        }
      }
      if (raw.destroyed !== null && raw.destroyed !== undefined && ids(raw.destroyed).length !== 0) {
        throw new JmapError('invalidResponse');
      }
      if (Object.prototype.hasOwnProperty.call(rejected, 'draft')) {
        const type = string(object(rejected.draft).type);
        const code = type === 'forbidden' ? 'forbidden' : type === 'overQuota' ? 'overQuota' :
          type === 'tooLarge' ? 'draftTooLarge' : type === 'invalidProperties' ? 'invalidDraft' : 'draftRejected';
        throw new JmapDraftError(code, false);
      }
      const result = object(created.draft);
      return { id: id(result.id), blobId: id(result.blobId), threadId: id(result.threadId),
        size: uint(result.size), state, mailboxId: mailbox.id };
    } catch (error) {
      if (error instanceof JmapDraftError) { throw error; }
      if (error instanceof JmapError && error.code === 'requestTooLarge') { throw error; }
      const status = error instanceof JmapError ? error.status : 0;
      throw new JmapDraftError('draftOutcomeUnknown', true, status);
    }
  }

  // This is an explicit desired value, never a server-side toggle. Patch only
  // the one key so concurrently added flags and mailbox membership survive.
  // A rejected/ambiguous response is surfaced; POST is never replayed here.
  async setKeyword(accountId: string, emailId: string, keyword: JmapKeyword, enabled: boolean): Promise<string> {
    id(emailId);
    if ((keyword !== '$seen' && keyword !== '$flagged') || typeof enabled !== 'boolean') {
      throw new JmapError('invalidArgument');
    }
    return this.patchEmail(accountId, emailId, { [`keywords/${keyword}`]: enabled ? true : null });
  }

  async archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    const boxes = await this.mailboxes(accountId);
    const snapshot = await this.getEmails(accountId, [id(emailId)], false);
    const mail = snapshot.emails[0];
    if (!mail) { throw new JmapError('messageNotFound'); }
    const archive = archiveTarget(mail, boxes);
    if (!archive) { throw new JmapError('archiveUnavailable'); }
    const inbox = boxes.find((box) => box.role === 'inbox')!;
    const addedArchive = !mail.mailboxIds.includes(archive.id);
    const patch: JsonObject = { [`mailboxIds/${inbox.id}`]: null };
    if (addedArchive) { patch[`mailboxIds/${archive.id}`] = true; }
    await this.patchEmail(accountId, mail.id, patch, snapshot.state);
    return { accountId, emailId, inboxId: inbox.id, archiveId: archive.id, addedArchive,
      expectedMailboxIds: mail.mailboxIds.filter((entry) => entry !== inbox.id).concat(addedArchive ? [archive.id] : []) };
  }

  async undoArchive(undo: JmapArchiveUndo): Promise<void> {
    id(undo.emailId); id(undo.inboxId); id(undo.archiveId); ids(undo.expectedMailboxIds);
    if (undo.inboxId === undo.archiveId || undo.expectedMailboxIds.includes(undo.inboxId) ||
      !undo.expectedMailboxIds.includes(undo.archiveId)) { throw new JmapError('invalidArgument'); }
    const boxes = await this.mailboxes(undo.accountId);
    const inbox = boxes.find((box) => box.id === undo.inboxId);
    const archive = boxes.find((box) => box.id === undo.archiveId);
    if (!inbox?.mayAddItems || (undo.addedArchive && !archive?.mayRemoveItems)) { throw new JmapError('forbidden'); }
    const snapshot = await this.getEmails(undo.accountId, [undo.emailId], false);
    const mail = snapshot.emails[0];
    if (!mail) { throw new JmapError('messageNotFound'); }
    if (mail.mailboxIds.length !== undo.expectedMailboxIds.length ||
      mail.mailboxIds.some((entry) => !undo.expectedMailboxIds.includes(entry))) { throw new JmapError('stateMismatch'); }
    const patch: JsonObject = { [`mailboxIds/${undo.inboxId}`]: true };
    if (undo.addedArchive) { patch[`mailboxIds/${undo.archiveId}`] = null; }
    // A new state from this read permits unrelated mail/keyword changes, while
    // the precondition prevents racing mailbox edits between this GET and SET.
    await this.patchEmail(undo.accountId, undo.emailId, patch, snapshot.state);
  }

  private async patchEmail(accountId: string, emailId: string, patch: JsonObject, ifInState?: string): Promise<string> {
    const session = await this.connect();
    const account = session.accounts.find((entry) => entry.id === accountId);
    if (!account) { throw new JmapError('accountNotFound'); }
    if (account.isReadOnly) { throw new JmapError('accountReadOnly'); }
    const raw = await this.call('Email/set', accountId, { update: { [emailId]: patch },
      ...(ifInState === undefined ? {} : { ifInState }) });
    nullableString(raw.oldState);
    const state = string(raw.newState);
    const updated = raw.updated === null ? {} : object(raw.updated);
    const notUpdated = raw.notUpdated === null ? {} : object(raw.notUpdated);
    const reported = Object.keys(updated).concat(Object.keys(notUpdated));
    if (reported.length !== 1 || reported[0] !== emailId) { throw new JmapError('invalidResponse'); }
    // We did not ask to create or destroy anything. Reject contradictory replies.
    for (const key of ['created', 'notCreated', 'notDestroyed']) {
      if (raw[key] !== undefined && raw[key] !== null && Object.keys(object(raw[key])).length > 0) {
        throw new JmapError('invalidResponse');
      }
    }
    if (raw.destroyed !== undefined && raw.destroyed !== null && ids(raw.destroyed).length > 0) {
      throw new JmapError('invalidResponse');
    }
    if (Object.prototype.hasOwnProperty.call(notUpdated, emailId)) {
      const type = string(object(notUpdated[emailId]).type);
      if (type === 'forbidden') { throw new JmapError('forbidden'); }
      if (type === 'notFound') { throw new JmapError('messageNotFound'); }
      throw new JmapError('updateRejected');
    }
    if (updated[emailId] !== null) { object(updated[emailId]); }
    // The caller refetches the message, including any server-side adjustments.
    return state;
  }

  private async getEmails(accountId: string, emailIds: string[], includeBody: boolean): Promise<{
    emails: JmapEmail[]; notFound: string[]; state: string;
  }> {
    const properties = includeBody ? SUMMARY_PROPERTIES.concat(['textBody', 'htmlBody', 'bodyValues']) : SUMMARY_PROPERTIES;
    const args: JsonObject = { ids: emailIds, properties };
    if (includeBody) {
      args.bodyProperties = ['partId', 'type'];
      args.fetchTextBodyValues = true;
      args.maxBodyValueBytes = 256 * 1024;
    }
    const raw = await this.call('Email/get', accountId, args);
    const notFound = ids(raw.notFound);
    const emails = array(raw.list).map((value) => email(value, includeBody));
    const returned = emails.map((entry) => entry.id).concat(notFound);
    if (new Set(returned).size !== returned.length || returned.length !== emailIds.length ||
      returned.some((entry) => !emailIds.includes(entry))) { throw new JmapError('invalidResponse'); }
    const byId = new Map(emails.map((entry) => [entry.id, entry]));
    return { emails: emailIds.filter((entry) => byId.has(entry)).map((entry) => byId.get(entry)!),
      notFound, state: string(raw.state) };
  }
}
