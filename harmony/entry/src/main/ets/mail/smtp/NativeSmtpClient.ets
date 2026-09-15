// MPL-2.0: https://mozilla.org/MPL/2.0/
import { smtpAccountRequest } from 'libthunderbird.so';
import { OutgoingAttachment, SmtpAttachmentData, SmtpAttachmentInput, outgoingAttachmentInput } from './OutgoingAttachments';
export { OutgoingAttachment, SmtpAttachmentData } from './OutgoingAttachments';

export class SmtpSettings {
  endpoint: string = '';
  username: string = '';
  password: string = '';
}
export class OutgoingDraft {
  id: string = '';
  date: number = 0;
  to: string = '';
  cc: string = '';
  bcc: string = '';
  subject: string = '';
  senderName: string = '';
  compositionApplied: boolean = false;
  text: string = '';
  forwardHtml: string = '';
  forwardWarning: string = '';
  state: string = 'draft';
  failureStage: string = '';
  failureCode: string = '';
  inReplyTo: string[] = [];
  references: string[] = [];
  attachments: OutgoingAttachment[] = [];
}
export interface SentCopyDestination { sessionUrl: string; authorization: string; username?: string; }
export interface SmtpSubmission {
  accepted: boolean; messageId: string; date: number; textBody: string | null; htmlBody: string | null;
  sentCopy: string; sentMailboxId?: string;
}
interface Request {
  attachments: SmtpAttachmentInput[];
  accessToken?: string;
  sentDestination?: SentCopyDestination;
  inReplyTo: string[]; references: string[]; forwardHtml: string;
  operation: string; endpoint: string; username: string; password: string;
  from: string; senderName: string; to: string[]; cc: string[]; bcc: string[]; subject: string; text: string; id: string; date: number;
}
interface Reply {
  accepted?: boolean; error?: string; messageId?: string; date?: number;
  textBody?: string; htmlBody?: string; sentCopy?: string; sentMailboxId?: string;
}
export class SmtpError extends Error {
  code: string;
  constructor(code: string) { super(code); this.code = code; }
}
function addresses(text: string): string[] {
  if (text.trim() === '') { return []; }
  const values = text.split(/[;,]/).map(value => value.trim());
  if (values.some(value => value === '')) { throw new SmtpError('invalidMessage'); }
  return values;
}
export async function submitMail(settings: SmtpSettings, from: string, draft: OutgoingDraft, validateOnly: boolean = false,
  accessToken?: string, sentDestination?: SentCopyDestination, attachmentData?: SmtpAttachmentData[]): Promise<SmtpSubmission> {
  let attachments: SmtpAttachmentInput[];
  try { attachments = outgoingAttachmentInput(draft.attachments, attachmentData, validateOnly); }
  catch (_) { throw new SmtpError('invalidMessage'); }
  const input: Request = { operation: validateOnly ? 'validate' : 'send', endpoint: settings.endpoint,
    attachments,
    username: settings.username, password: accessToken === undefined ? settings.password : '', accessToken: accessToken,
    sentDestination: validateOnly ? undefined : sentDestination, from, senderName: draft.senderName ?? '',
    to: addresses(draft.to), cc: addresses(draft.cc), bcc: addresses(draft.bcc), subject: draft.subject,
    text: draft.text, forwardHtml: draft.forwardHtml ?? '', id: draft.id, date: draft.date, inReplyTo: draft.inReplyTo ?? [], references: draft.references ?? [] };
  let reply: Reply;
  try { reply = JSON.parse(await smtpAccountRequest(JSON.stringify(input))) as Reply; }
  catch (_) { throw new SmtpError(validateOnly ? 'invalidMessage' : 'deliveryUnconfirmed'); }
  if (reply.error) { throw new SmtpError(reply.error); }
  if (!validateOnly && reply.accepted !== true) { throw new SmtpError('deliveryUnconfirmed'); }
  return { accepted: reply.accepted === true, messageId: reply.messageId ?? '', date: reply.date ?? draft.date,
    textBody: reply.textBody ?? null, htmlBody: reply.htmlBody ?? null,
    sentCopy: reply.sentCopy ?? 'failed', sentMailboxId: reply.sentMailboxId };
}
