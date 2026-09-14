// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { JmapEmail, JmapMailbox } from '../mail/jmap/JmapClient';

export interface CachedEmail { version: number; savedAt: number; bodySavedAt: number | null; bodyDecoderRevision?: number; mail: JmapEmail; stateDirty?: boolean; summaryOnly?: boolean; }
export interface CachedView { version: number; savedAt: number; mailboxId: string; ids: string[]; nextPosition?: number | null; queryState?: string; }
export interface CachedBoxes { version: number; savedAt: number; boxes: JmapMailbox[]; readOnly?: boolean; roleRevision?: number; }
export interface CachedMailList { savedAt: number; emails: JmapEmail[]; nextPosition?: number | null; queryState?: string; stateDirty?: boolean; }
export const MAIL_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const BODY_DECODER_REVISION = 1;
export const MAILBOX_ROLE_REVISION = 2;
export function cacheIsFresh(savedAt: number | null, now: number = Date.now()): boolean {
  return savedAt !== null && savedAt <= now && now - savedAt < MAIL_RETENTION_MS;
}
export function cacheReadyForReading(cached: CachedEmail | null, now: number = Date.now()): boolean {
  return cached !== null && cached.bodyDecoderRevision === BODY_DECODER_REVISION &&
    cacheIsFresh(cached.bodySavedAt, now) && !cached.mail.bodyTruncated &&
    !cached.mail.bodyEncodingProblem && (!cached.mail.hasAttachment || cached.mail.attachments !== undefined);
}
export function retainedEmail(cached: CachedEmail, now: number = Date.now()): CachedEmail {
  if (cacheIsFresh(cached.bodySavedAt, now)) { return cached; }
  return { ...cached, bodySavedAt: null, mail: { ...cached.mail, textBody: null, htmlBody: null,
    attachments: undefined, bodyTruncated: false, bodyEncodingProblem: false } };
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
function attachments(value: unknown): boolean {
  return Array.isArray(value) && value.length <= 512 && value.every(v => {
    const a = obj(v); return typeof a.id === 'string' && /^[0-9]+(?:\.[0-9]+)*$|^legacy:[0-9]+$/.test(a.id) &&
      a.id.length <= 256 && typeof a.name === 'string' && a.name.length <= 1024 &&
      typeof a.contentType === 'string' && a.contentType.length <= 256 &&
      Number.isSafeInteger(a.size) && (a.size as number) >= 0 && typeof a.sizeIsEncoded === 'boolean';
  });
}
function envelope(text: string): Obj {
  if (text.length > 8 * 1024 * 1024) { throw new Error('Invalid mail cache'); }
  const raw = obj(JSON.parse(text));
  if (raw.version !== 1 || !timestamp(raw.savedAt)) { throw new Error('Invalid mail cache'); }
  return raw;
}
export function decodeCachedEmail(text: string): CachedEmail {
  const raw = envelope(text); const mail = obj(raw.mail);
  if ((raw.bodySavedAt !== null && !timestamp(raw.bodySavedAt)) || !ids([mail.id]) ||
    (raw.bodyDecoderRevision !== undefined && (!Number.isSafeInteger(raw.bodyDecoderRevision) || (raw.bodyDecoderRevision as number) < 1)) ||
    typeof mail.threadId !== 'string' || !/^[A-Za-z0-9_-]{1,4096}$/.test(mail.threadId) ||
    !ids(mail.mailboxIds) || !strings(mail.messageIds) || !strings(mail.keywords) ||
    (mail.cc !== undefined && !addresses(mail.cc)) ||
    (mail.inReplyTo !== undefined && !strings(mail.inReplyTo)) ||
    (mail.references !== undefined && !strings(mail.references)) ||
    (mail.attachments !== undefined && !attachments(mail.attachments)) ||
    !addresses(mail.from) || !addresses(mail.to) || !addresses(mail.replyTo) ||
    typeof mail.subject !== 'string' || typeof mail.preview !== 'string' || (typeof mail.receivedAt !== 'number' || !Number.isFinite(mail.receivedAt)) ||
    (mail.htmlBody !== undefined && mail.htmlBody !== null && typeof mail.htmlBody !== 'string') ||
    typeof mail.hasAttachment !== 'boolean' || (mail.textBody !== null && typeof mail.textBody !== 'string') ||
    typeof mail.bodyTruncated !== 'boolean' || typeof mail.bodyEncodingProblem !== 'boolean' || typeof mail.hasHtmlBody !== 'boolean') {
    throw new Error('Invalid mail cache');
  }
  return raw as unknown as CachedEmail;
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
    if (typeof box.name !== 'string' || (box.parentId !== null && !ids([box.parentId])) ||
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
  if (previous) { previous = retainedEmail(previous, now); }
  if (previous?.mail.id !== mail.id) { previous = null; }
  const copy = JSON.parse(JSON.stringify(mail)) as JmapEmail;
  if (!fullBody && previous?.mail.id === mail.id && previous.bodySavedAt !== null) {
    copy.references = previous.mail.references ?? copy.references;
    copy.htmlBody = previous.mail.htmlBody; copy.textBody = previous.mail.textBody; copy.bodyTruncated = previous.mail.bodyTruncated;
    copy.bodyEncodingProblem = previous.mail.bodyEncodingProblem; copy.hasHtmlBody = previous.mail.hasHtmlBody;
    copy.attachments = previous.mail.attachments; copy.hasAttachment = previous.mail.hasAttachment;
  }
  return decodeCachedEmail(JSON.stringify({ version: 1, savedAt: now,
    bodySavedAt: fullBody ? now : previous?.bodySavedAt ?? null,
    bodyDecoderRevision: fullBody ? BODY_DECODER_REVISION : previous?.bodyDecoderRevision, mail: copy }));
}
