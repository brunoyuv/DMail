// MPL-2.0: https://mozilla.org/MPL/2.0/
import { JmapEmail, JmapAddress } from '../jmap/JmapClient';

export class ReplyContent {
  to: string = '';
  cc: string = '';
  subject: string = '';
  text: string = '';
  forwardHtml: string = '';
  forwardWarning: string = '';
  inReplyTo: string[] = [];
  references: string[] = [];
}
function messageIds(values: string[]): string[] {
  const result: string[] = [];
  for (const raw of values) {
    const id = raw.startsWith('<') && raw.endsWith('>') ? raw.slice(1, -1) : raw;
    if (id.length <= 900 && /^[A-Za-z0-9!#$%&'*+\-/=?^_`{|}~.]+@[A-Za-z0-9.\-\[\]:]+$/.test(id) && !result.includes(id)) { result.push(id); }
  }
  // Keep the root and the most recent ancestry, including the direct parent.
  return result.length <= 100 ? result : [result[0], ...result.slice(-99)];
}
export function replyContent(mail: JmapEmail, identity: string, all: boolean): ReplyContent {
  const seen: string[] = [identity.trim().toLowerCase()];
  const collect = (addresses: JmapAddress[]): string[] => {
    const result: string[] = [];
    for (const address of addresses) {
      const value = address.email.trim();
      if (!/^[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(value) || value.includes('..') || value.length > 254) {
        throw new Error('unsupportedRecipient');
      }
      if (!seen.includes(value.toLowerCase())) { seen.push(value.toLowerCase()); result.push(value); }
    }
    return result;
  };
  const result = new ReplyContent();
  let to = collect(mail.replyTo.length > 0 ? mail.replyTo : mail.from);
  if (all || to.length === 0) { to = to.concat(collect(mail.to)); }
  result.to = to.join(', ');
  result.cc = all ? collect(mail.cc ?? []).join(', ') : '';
  const subject = mail.subject.replace(/[\x00-\x1f\x7f]/g, ' ').trim();
  result.subject = Array.from(/^re\s*:/i.test(subject) ? subject : `Re: ${subject}`).slice(0, 240).join('');
  const source = (mail.textBody ?? '').replace(/\r\n?/g, '\n').replace(/\x00/g, '');
  const quoted = Array.from(source).slice(0, 15000).join('');
  const sender = mail.from.map(value => value.name || value.email).join(', ').replace(/[\r\n]/g, ' ');
  result.text = quoted ? `\n\nOn ${new Date(mail.receivedAt).toLocaleString()}, ${sender} wrote:\n${quoted.split('\n').map(line => `> ${line}`).join('\n')}${source.length > quoted.length || mail.bodyTruncated ? '\n> [Quoted message truncated]' : ''}` : '';
  result.inReplyTo = messageIds(mail.messageIds).slice(-1);
  const ancestry = mail.references?.length ? mail.references : mail.inReplyTo ?? [];
  result.references = messageIds(ancestry.concat(result.inReplyTo));
  return result;
}

function forwardHeader(value: string): string { return value.replace(/[\x00-\x1f\x7f]/g, ' ').trim(); }
function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
export function forwardContent(mail: JmapEmail): ReplyContent {
  const result = new ReplyContent();
  const subject = forwardHeader(mail.subject);
  result.subject = Array.from(/^(fwd?|fw)\s*:/i.test(subject) ? subject : `Fwd: ${subject}`).slice(0, 240).join('');
  const addresses = (values: JmapAddress[]): string => values.map(address =>
    forwardHeader(address.name ? `${address.name} <${address.email}>` : address.email)).join(', ');
  const lines = ['---------- Forwarded message ----------', `From: ${addresses(mail.from)}`,
    `Date: ${new Date(mail.receivedAt).toLocaleString()}`, `Subject: ${subject}`, `To: ${addresses(mail.to)}`];
  if (mail.cc?.length) { lines.push(`Cc: ${addresses(mail.cc)}`); }
  const header = lines.join('\n');
  // An inline forward starts a new conversation with no recipients or reply headers.
  if (header.length > 8000) { throw new Error('forwardTooLarge'); }
  if (mail.htmlBody) {
    if (Array.from(mail.htmlBody).length > 100000) { throw new Error('forwardTooLarge'); }
    result.forwardHtml = `<div style="white-space:pre-wrap">${escapeHtml(header)}</div><br>${mail.htmlBody}`;
  } else {
    const text = (mail.textBody ?? '').replace(/\r\n?/g, '\n').replace(/\x00/g, '');
    if (header.length + text.length > 50000) { throw new Error('forwardTooLarge'); }
    result.text = `\n\n${header}\n\n${text}`;
  }
  const warnings: string[] = [];
  if (mail.hasAttachment) { warnings.push('Attachments are not included.'); }
  if (mail.bodyTruncated) { warnings.push('Only the downloaded portion of this message is included.'); }
  if (mail.bodyEncodingProblem) { warnings.push('Some original text could not be decoded.'); }
  result.forwardWarning = warnings.join(' ');
  return result;
}
