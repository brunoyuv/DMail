// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { JmapEmail, JmapMailbox, validArchiveDestinationHint } from '../mail/jmap/JmapClient';
import { messagePreview } from '../mail/MessagePreview';
import { mailContentReference } from './MailContentFileModel';

export interface CachedBodyFiles { text?: string; html?: string; }
export interface CachedEmail { version: number; savedAt: number; bodySavedAt: number | null; bodyDecoderRevision?: number; bodyFiles?: CachedBodyFiles; mail: JmapEmail; stateDirty?: boolean; summaryOnly?: boolean; }
export interface CachedView { version: number; savedAt: number; mailboxId: string; ids: string[]; nextPosition?: number | null; queryState?: string; }
export interface CachedBoxes { version: number; savedAt: number; boxes: JmapMailbox[]; readOnly?: boolean; roleRevision?: number; }
export interface CachedMailList { savedAt: number; emails: JmapEmail[]; nextPosition?: number | null; queryState?: string; stateDirty?: boolean; }
export function withCachedBodyFiles(cached: CachedEmail, files: CachedBodyFiles): CachedEmail {
  return { ...cached, bodyFiles: files, mail: { ...cached.mail,
    textBody: files.text ? null : cached.mail.textBody, htmlBody: files.html ? null : cached.mail.htmlBody } };
}
export function hydratedCachedEmail(cached: CachedEmail, textBody: string | null, htmlBody: string | null | undefined): CachedEmail | null {
  const result: CachedEmail = { ...cached, mail: { ...cached.mail, textBody, htmlBody } };
  return validTextBody(textBody) && validHtmlBody(htmlBody) ? result : null;
}
export function missingCachedEmail(cached: CachedEmail): CachedEmail {
  return cachedEmailSummary({ ...cached, bodySavedAt: null, bodyFiles: undefined });
}
// Body files have their own limits. Do not serialize their contents into the
// metadata-size budget on every save or reopen; HTML plus its text alternative
// can exceed that old inline-row budget even when both files are valid.
export const MAX_MAIL_BODY_CHARACTERS = 8 * 1024 * 1024;
function validTextBody(value: unknown): boolean {
  return value === null || (typeof value === 'string' && value.length <= MAX_MAIL_BODY_CHARACTERS);
}
function validHtmlBody(value: unknown): boolean { return value === undefined || validTextBody(value); }
export const MAIL_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const BODY_DECODER_REVISION = 1;
export const MAILBOX_ROLE_REVISION = 5;
// A decoder failure with no body is not a completed download. Empty strings
// are valid decoded bodies; readable partial mail and attachments stay usable.
export function failedEmptyMailBody(mail: JmapEmail): boolean {
  return mail.bodyEncodingProblem === true && mail.textBody === null && mail.htmlBody == null;
}
export function cacheIsFresh(savedAt: number | null, now: number = Date.now()): boolean {
  return savedAt !== null && savedAt <= now && now - savedAt < MAIL_RETENTION_MS;
}
export function cacheReadyForReading(cached: CachedEmail | null, now: number = Date.now()): boolean {
  return cached !== null && cached.summaryOnly !== true && cached.bodyDecoderRevision === BODY_DECODER_REVISION &&
    cacheIsFresh(cached.bodySavedAt, now) && !cached.mail.bodyTruncated &&
    !cached.mail.bodyEncodingProblem && (!cached.mail.hasAttachment || cached.mail.attachments !== undefined);
}
export function retainedEmail(cached: CachedEmail, now: number = Date.now()): CachedEmail {
  if (cacheIsFresh(cached.bodySavedAt, now)) { return cached; }
  return { ...cached, bodySavedAt: null, bodyFiles: undefined, mail: { ...cached.mail, textBody: null, htmlBody: null,
    attachments: undefined, bodyTruncated: false, bodyEncodingProblem: false } };
}

// Header consumers retain conversation ranking without holding downloaded body
// strings or attachment metadata. This marker must never count as reader data.
export function cachedEmailSummary(cached: CachedEmail, now: number = Date.now()): CachedEmail {
  const retained = retainedEmail(cached, now);
  const available = cacheIsFresh(retained.bodySavedAt, now) && (retained.mail.cachedBodyAvailable === true ||
    retained.bodyFiles?.text !== undefined || retained.bodyFiles?.html !== undefined ||
    typeof retained.mail.textBody === 'string' || typeof retained.mail.htmlBody === 'string' ||
    (!failedEmptyMailBody(retained.mail) && (retained.mail.attachments?.length ?? 0) > 0));
  return { ...retained, summaryOnly: true, mail: { ...retained.mail, textBody: null, htmlBody: null,
    attachments: undefined, cachedBodyAvailable: available } };
}

type Obj = Record<string, unknown>;
function obj(value: unknown): Obj {
  if (!value || typeof value !== 'object' || Array.isArray(value)) { throw new Error('Invalid mail cache'); }
  return value as Obj;
}
function strings(value: unknown): value is string[] { return Array.isArray(value) && value.every(v => typeof v === 'string'); }
function ids(value: unknown): value is string[] {
  return strings(value) && value.every(v => /^[A-Za-z0-9_-]{1,4096}$/.test(v)) && new Set(value).size === value.length;
}
function addresses(value: unknown): boolean {
  return Array.isArray(value) && value.every(v => {
    const a = obj(v); return typeof a.name === 'string' && typeof a.email === 'string';
  });
}
function timestamp(value: unknown): boolean { return typeof value === 'number' && Number.isFinite(value) && value >= 0; }
const LOCAL_ATTACHMENT_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function localSentOrigin(value: unknown): boolean {
  return typeof value === 'string' && value.startsWith('local_sent_') && LOCAL_ATTACHMENT_UUID.test(value.slice(11));
}
// Cache aliases are used only inside the captured account's private directory.
// Keep the latest identities and the selected immutable body's origin first.
export function attachmentCacheSources(mail: JmapEmail): string[] {
  const values = [mail.id].concat(mail.cachedSourceId ? [mail.cachedSourceId] : [], mail.cachedAttachmentSourceIds || []);
  return Array.from(new Set(values)).slice(0, 16);
}
function attachments(value: unknown, allowLocal: boolean): boolean {
  return Array.isArray(value) && value.length <= 512 && value.every(v => {
    const a = obj(v); return typeof a.id === 'string' &&
      (/^[0-9]+(?:\.[0-9]+)*$|^legacy:[0-9]+$/.test(a.id) || (allowLocal && LOCAL_ATTACHMENT_UUID.test(a.id))) &&
      a.id.length <= 256 && typeof a.name === 'string' && a.name.length <= 1024 &&
      typeof a.contentType === 'string' && a.contentType.length <= 256 &&
      Number.isSafeInteger(a.size) && (a.size as number) >= 0 && typeof a.sizeIsEncoded === 'boolean';
  });
}
function bodyFiles(value: unknown): boolean {
  if (value === undefined) { return true; }
  if (!value || typeof value !== 'object' || Array.isArray(value)) { return false; }
  const files = value as Obj;
  return Object.keys(files).every(key => key === 'text' || key === 'html') &&
    (files.text !== undefined || files.html !== undefined) &&
    (files.text === undefined || (typeof files.text === 'string' && mailContentReference(files.text, 'text'))) &&
    (files.html === undefined || (typeof files.html === 'string' && mailContentReference(files.html, 'html')));
}
function envelope(text: string): Obj {
  if (text.length > 8 * 1024 * 1024) { throw new Error('Invalid mail cache'); }
  const raw = obj(JSON.parse(text));
  if (raw.version !== 1 || !timestamp(raw.savedAt)) { throw new Error('Invalid mail cache'); }
  return raw;
}
function parseCachedEmail(text: string): CachedEmail {
  const raw = envelope(text); const mail = obj(raw.mail);
  if ((raw.bodySavedAt !== null && !timestamp(raw.bodySavedAt)) || !bodyFiles(raw.bodyFiles) || !ids([mail.id]) ||
    (raw.bodyDecoderRevision !== undefined && (!Number.isSafeInteger(raw.bodyDecoderRevision) || (raw.bodyDecoderRevision as number) < 1)) ||
    typeof mail.threadId !== 'string' || !/^[A-Za-z0-9_-]{1,4096}$/.test(mail.threadId) ||
    !ids(mail.mailboxIds) || !strings(mail.messageIds) || !strings(mail.keywords) ||
    (mail.cc !== undefined && !addresses(mail.cc)) ||
    (mail.inReplyTo !== undefined && !strings(mail.inReplyTo)) ||
    (mail.references !== undefined && !strings(mail.references)) ||
    (mail.cachedSourceId !== undefined && !ids([mail.cachedSourceId])) ||
    (mail.cachedAttachmentSourceIds !== undefined && (!Array.isArray(mail.cachedAttachmentSourceIds) ||
      mail.cachedAttachmentSourceIds.length > 16 || !ids(mail.cachedAttachmentSourceIds))) ||
    (mail.attachments !== undefined && !attachments(mail.attachments, localSentOrigin(mail.id) || localSentOrigin(mail.cachedSourceId))) ||
    !addresses(mail.from) || !addresses(mail.to) || !addresses(mail.replyTo) ||
    typeof mail.subject !== 'string' || typeof mail.preview !== 'string' || (typeof mail.receivedAt !== 'number' || !Number.isFinite(mail.receivedAt)) ||
    (mail.htmlBody !== undefined && mail.htmlBody !== null && typeof mail.htmlBody !== 'string') ||
    typeof mail.hasAttachment !== 'boolean' || (mail.textBody !== null && typeof mail.textBody !== 'string') ||
    typeof mail.bodyTruncated !== 'boolean' || typeof mail.bodyEncodingProblem !== 'boolean' || typeof mail.hasHtmlBody !== 'boolean') {
    throw new Error('Invalid mail cache');
  }
  return raw as unknown as CachedEmail;
}
export function decodeCachedEmail(text: string): CachedEmail {
  const cached = parseCachedEmail(text);
  // Upgrade existing downloaded bodies in place when their old decoder left
  // the summary blank. This does not change body retention or fetch anything.
  cached.mail.preview = messagePreview(cached.mail);
  return cached;
}

// Startup still validates every record, but normally has nothing to rewrite.
// Keep the original bytes unless retention or the legacy preview needs repair.
export function prunedEmailPayload(text: string, now: number = Date.now()): string | null {
  const cached = parseCachedEmail(text);
  if (!cacheIsFresh(cached.savedAt, now)) { return null; }
  const preview = messagePreview(cached.mail);
  const retained = retainedEmail(cached, now);
  const bodyUnchanged = retained === cached || (retained.bodySavedAt === cached.bodySavedAt &&
    retained.mail.textBody === cached.mail.textBody && retained.mail.htmlBody === cached.mail.htmlBody &&
    retained.mail.attachments === cached.mail.attachments && retained.mail.bodyTruncated === cached.mail.bodyTruncated &&
    retained.mail.bodyEncodingProblem === cached.mail.bodyEncodingProblem);
  if (bodyUnchanged && preview === cached.mail.preview) { return text; }
  retained.mail.preview = preview;
  return JSON.stringify(retained);
}
export function decodeCachedView(text: string): CachedView {
  const raw = envelope(text);
  if (!ids([raw.mailboxId]) || !ids(raw.ids) ||
    (raw.nextPosition !== undefined && raw.nextPosition !== null &&
      (!Number.isSafeInteger(raw.nextPosition) || (raw.nextPosition as number) < 0)) ||
    (raw.queryState !== undefined && typeof raw.queryState !== 'string')) { throw new Error('Invalid mail cache'); }
  return raw as unknown as CachedView;
}
export function decodeCachedBoxes(text: string): CachedBoxes {
  const raw = envelope(text);
  if (!Array.isArray(raw.boxes) || !ids(raw.boxes.map(v => obj(v).id)) ||
    (raw.readOnly !== undefined && typeof raw.readOnly !== 'boolean')) { throw new Error('Invalid mail cache'); }
  for (const value of raw.boxes) {
    const box = obj(value);
    if (!validArchiveDestinationHint(box as unknown as JmapMailbox) || typeof box.name !== 'string' || (box.parentId !== null && !ids([box.parentId])) ||
      (box.role !== null && typeof box.role !== 'string') ||
      ['sortOrder', 'totalEmails', 'unreadEmails'].some(k => !Number.isSafeInteger(box[k]) || (box[k] as number) < 0) ||
      (box.countsKnown !== undefined && typeof box.countsKnown !== 'boolean') ||
      ['maySetSeen', 'maySetKeywords', 'mayAddItems', 'mayRemoveItems'].some(k => typeof box[k] !== 'boolean')) {
      throw new Error('Invalid mail cache');
    }
  }
  return raw as unknown as CachedBoxes;
}
export function cacheEmail(mail: JmapEmail, fullBody: boolean, previous: CachedEmail | null, now: number): CachedEmail {
  if (fullBody && mail.cachedBodyAvailable !== undefined) { throw new Error('Header-only mail cannot be saved as a body'); }
  if (previous) { previous = retainedEmail(previous, now); }
  if (previous?.mail.id !== mail.id) { previous = null; }
  // Deep-copy and validate metadata separately. Body strings are immutable and
  // must not be copied through JSON merely to reach their private files.
  const copy: JmapEmail = { ...mail };
  copy.cachedBodyAvailable = undefined;
  copy.cachedSourceId = previous?.mail.cachedSourceId ?? copy.cachedSourceId;
  copy.cachedAttachmentSourceIds = previous?.mail.cachedAttachmentSourceIds?.slice() ?? copy.cachedAttachmentSourceIds?.slice();
  copy.preview = messagePreview(copy) || previous?.mail.preview || '';
  if (!fullBody && previous?.mail.id === mail.id && previous.bodySavedAt !== null) {
    copy.references = previous.mail.references ?? copy.references;
    copy.htmlBody = previous.mail.htmlBody; copy.textBody = previous.mail.textBody; copy.bodyTruncated = previous.mail.bodyTruncated;
    copy.bodyEncodingProblem = previous.mail.bodyEncodingProblem; copy.hasHtmlBody = previous.mail.hasHtmlBody;
    copy.attachments = previous.mail.attachments; copy.hasAttachment = previous.mail.hasAttachment;
    if (previous.bodyFiles?.text !== undefined) { copy.textBody = null; }
    if (previous.bodyFiles?.html !== undefined) { copy.htmlBody = null; }
  }
  const text = copy.textBody, html = copy.htmlBody;
  if (!validTextBody(text) || !validHtmlBody(html)) { throw new Error('Invalid mail cache body'); }
  const validated = decodeCachedEmail(JSON.stringify({ version: 1, savedAt: now,
    bodySavedAt: fullBody ? now : previous?.bodySavedAt ?? null,
    bodyFiles: fullBody ? undefined : previous?.bodyFiles,
    bodyDecoderRevision: fullBody ? BODY_DECODER_REVISION : previous?.bodyDecoderRevision,
    mail: { ...copy, textBody: null, htmlBody: html === undefined ? undefined : null } }));
  validated.mail.textBody = text;
  if (html !== undefined) { validated.mail.htmlBody = html; }
  return validated;
}
