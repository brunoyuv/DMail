// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { JmapEmail, JmapEmailPage } from '../mail/jmap/JmapClient';

export type MailSyncStage = 'body' | 'pictures';
export interface MailSyncJob {
  accountId: string; email: JmapEmail; stage: MailSyncStage;
  attempts: number; retryAt: number; bodySavedAt: number; messageKey: string;
}
export interface MailSyncCursor {
  accountId: string; mailboxId: string; head: string; revision: number;
  position: number | null; queryState: string; attempts: number; retryAt: number;
}

export const MAX_MAIL_SYNC_PAYLOAD = 512 * 1024;

export function mailSyncIdentity(value: string): boolean {
  return typeof value === 'string' && value.length > 0 && value.length <= 4096;
}

function strings(values: string[], limit: number): string[] {
  if (!Array.isArray(values)) { return []; }
  return values.filter(value => typeof value === 'string' && value.length <= 4096).slice(0, limit);
}

// Jobs retain protocol identity and stable-key headers only. Bodies, addresses,
// previews and attachments live in their existing encrypted caches. In
// particular, enqueueing a large fetched body never copies it into this queue.
export function encodeMailSyncEmail(email: JmapEmail): string {
  if (!email || !mailSyncIdentity(email.id)) { throw new Error('Invalid mail sync identity'); }
  const value: JmapEmail = {
    id: email.id, threadId: typeof email.threadId === 'string' ? email.threadId.slice(0, 4096) : '',
    messageIds: strings(email.messageIds, 32), mailboxIds: strings(email.mailboxIds, 32),
    keywords: [], from: [], to: [], replyTo: [], subject: '', preview: '',
    receivedAt: Number.isFinite(email.receivedAt) ? email.receivedAt : 0,
    hasAttachment: email.hasAttachment === true, textBody: null, htmlBody: null,
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: email.hasHtmlBody === true
  };
  const payload = JSON.stringify(value);
  if (payload.length > MAX_MAIL_SYNC_PAYLOAD) { throw new Error('Invalid mail sync metadata'); }
  return payload;
}

export function decodeMailSyncEmail(payload: string, emailId: string): JmapEmail {
  if (payload.length > MAX_MAIL_SYNC_PAYLOAD) { throw new Error('Invalid mail sync metadata'); }
  let value: JmapEmail;
  try { value = JSON.parse(payload) as JmapEmail; }
  catch (_) { throw new Error('Invalid mail sync metadata'); }
  if (!value || value.id !== emailId) { throw new Error('Invalid mail sync identity'); }
  return JSON.parse(encodeMailSyncEmail(value)) as JmapEmail;
}

export function validateMailSyncPage(page: JmapEmailPage): void {
  if (!page || !Number.isSafeInteger(page.position) || page.position < 0 ||
    (page.nextPosition !== null && (!Number.isSafeInteger(page.nextPosition) || page.nextPosition <= page.position)) ||
    typeof page.queryState !== 'string' || page.queryState.length > 65536 || !Array.isArray(page.emails)) {
    throw new Error('Invalid mail sync page');
  }
}

export function mailSyncHead(page: JmapEmailPage): string {
  validateMailSyncPage(page);
  if (page.position !== 0) { throw new Error('Invalid mail sync first page'); }
  // The exact bounded server cursor and IDs avoid hash collisions. Native
  // provider pages are bounded; reject invalid oversize metadata explicitly.
  const value = JSON.stringify([page.queryState, page.nextPosition, page.emails.map(email => email.id)]);
  if (value.length > MAX_MAIL_SYNC_PAYLOAD) { throw new Error('Invalid mail sync page'); }
  return value;
}
