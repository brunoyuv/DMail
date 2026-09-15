// MPL-2.0: https://mozilla.org/MPL/2.0/
import { JmapAddress, JmapEmail, JmapMailbox, MailAttachment } from '../jmap/JmapClient';
import { OutgoingAttachment } from './OutgoingAttachments';

export const LOCAL_SENT_MAILBOX = 'local_sent';
export interface SentDraft {
  id: string; to: string; cc: string; subject: string; senderName?: string; inReplyTo: string[]; references: string[];
  attachments?: OutgoingAttachment[];
}
export interface SubmittedMail {
  accepted: boolean; messageId: string; date: number; textBody: string | null; htmlBody: string | null;
  sentCopy: string; sentMailboxId?: string;
}

function addresses(value: string): JmapAddress[] {
  // SMTP's original Swift validator has already accepted these plain addresses.
  return value.trim() === '' ? [] : value.split(/[;,]/).map(email => ({ name: '', email: email.trim() }));
}
function identifier(value: string): string { return value.trim().replace(/^<|>$/g, ''); }

export function serverSentMailbox(boxes: JmapMailbox[]): JmapMailbox | null {
  const candidates = boxes.filter(box => box.role === 'sent' && !box.id.startsWith('local_'));
  return candidates.length === 1 ? candidates[0] : null;
}

export function sentMailbox(boxes: JmapMailbox[], submission: SubmittedMail): JmapMailbox {
  const existing = submission.sentMailboxId ? boxes.find(box => box.id === submission.sentMailboxId) : serverSentMailbox(boxes);
  if (existing) { return { ...existing, role: submission.sentMailboxId ? 'sent' : existing.role }; }
  return { id: submission.sentMailboxId || LOCAL_SENT_MAILBOX, name: submission.sentMailboxId ? 'Sent' : 'Sent on this device',
    parentId: null, role: submission.sentMailboxId ? 'sent' : null,
    sortOrder: 2, totalEmails: 0, unreadEmails: 0, countsKnown: false,
    maySetSeen: false, maySetKeywords: false, mayAddItems: false, mayRemoveItems: false };
}

export function sentMessage(from: string, draft: SentDraft, submission: SubmittedMail, mailboxId: string): JmapEmail {
  if (!submission.accepted || identifier(submission.messageId) === '') { throw new Error('Sent message is not confirmed'); }
  const id = `local_sent_${draft.id}`;
  return { id, threadId: id, messageIds: [identifier(submission.messageId)], mailboxIds: [mailboxId], keywords: ['$seen'],
    from: [{ name: draft.senderName?.trim() || '', email: from }], to: addresses(draft.to), cc: addresses(draft.cc), replyTo: [],
    inReplyTo: draft.inReplyTo.slice(), references: draft.references.slice(), subject: draft.subject,
    preview: (submission.textBody || '').replace(/\s+/g, ' ').trim().slice(0, 240), receivedAt: submission.date,
    hasAttachment: (draft.attachments?.length ?? 0) > 0,
    attachments: (draft.attachments ?? []).map((attachment: OutgoingAttachment): MailAttachment => ({ id: attachment.id, name: attachment.name,
      contentType: attachment.contentType, size: attachment.size, sizeIsEncoded: false })),
    textBody: submission.textBody ?? (submission.htmlBody === null ? '' : null), htmlBody: submission.htmlBody,
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: submission.htmlBody !== null,
    maySetSeen: false, maySetKeywords: false };
}

export function prependSentMessage(mail: JmapEmail, existing: JmapEmail[]): JmapEmail[] {
  const ids = mail.messageIds.map(identifier);
  // A server copy wins if it was fetched before the SMTP completion callback.
  const server = existing.find(value => !value.id.startsWith('local_sent_') &&
    (value.textBody !== null || typeof value.htmlBody === 'string') && !value.bodyTruncated && !value.bodyEncodingProblem &&
    value.messageIds.some(value => ids.includes(identifier(value))));
  if (server) { return existing.filter(value => value.id !== mail.id); }
  return [mail, ...existing.filter(value => value.id !== mail.id &&
    !value.messageIds.some(value => ids.includes(identifier(value))))];
}

export interface SendFailureDetail { failureStage?: string; failureCode?: string; }

export function safeSendFailureCode(code: string | undefined): string {
  return code === 'authenticationRequired' || code === 'network' || code === 'certificate' ||
    code === 'unsafeEndpoint' || code === 'rejected' || code === 'invalidMessage' || code === 'deliveryUnconfirmed' ? code : 'unknown';
}

export function setSendFailure(detail: SendFailureDetail, stage: string, code: string | undefined): void {
  detail.failureStage = stage === 'authRefresh' || stage === 'smtp' || stage === 'preflight' ? stage : '';
  detail.failureCode = detail.failureStage ? safeSendFailureCode(code) : '';
}

export function sendFailureDiagnostic(detail: SendFailureDetail): string {
  const stage = detail.failureStage === 'authRefresh' ? 'AUTH' : detail.failureStage === 'smtp' ? 'SMTP' :
    detail.failureStage === 'preflight' ? 'CHECK' : '';
  return stage ? `${stage}/${safeSendFailureCode(detail.failureCode)}` : '';
}

export function sendFailureState(attempted: boolean, code: string | undefined): string {
  return attempted && (code === 'deliveryUnconfirmed' || safeSendFailureCode(code) === 'unknown') ? 'unconfirmed' : 'draft';
}
export function sendFailureLabel(state: string, code: string | undefined): string {
  return code === 'authenticationRequired' ? 'smtp_auth_error' : code === 'invalidMessage' ? 'send_invalid' :
    code === 'unsafeEndpoint' || code === 'certificate' ? 'smtp_tls_error' : code === 'rejected' ? 'smtp_rejected' :
    state === 'unconfirmed' ? 'delivery_uncertain' : 'smtp_network_error';
}
export function sentCompletionLabel(sentCopy: string): string {
  return sentCopy === 'server' || sentCopy === 'saved' ? 'sent' :
    sentCopy === 'unconfirmed' ? 'sent_copy_unconfirmed' : 'sent_copy_failed';
}
