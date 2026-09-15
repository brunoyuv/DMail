// MPL-2.0: https://mozilla.org/MPL/2.0/
import { JmapAddress, JmapEmail, JmapMailbox } from '../mail/jmap/JmapClient';

export interface RecipientRecord { email: string; name: string; lastUsed: number; }
export interface RecipientFields { to: string; cc: string; bcc: string; }
export interface RecipientToken { start: number; end: number; query: string; }
export const RECIPIENT_HISTORY_LIMIT = 500;

function cleanName(name: string): string { return name.replace(/[\x00-\x1f\x7f]/g, ' ').trim().slice(0, 256); }
function addressKey(email: string): string { return email.trim().toLowerCase(); }
function usable(email: string): boolean { return email.length <= 512 && /^[^\s<>,;]+@[^\s<>,;]+$/.test(email); }

export function mergeRecipients(existing: RecipientRecord[], added: RecipientRecord[]): RecipientRecord[] {
  const values = new Map<string, RecipientRecord>();
  for (const record of existing.concat(added)) {
    const email = record.email.trim(), key = addressKey(email);
    if (!usable(email) || !Number.isFinite(record.lastUsed) || record.lastUsed < 0) { continue; }
    const previous = values.get(key), name = cleanName(record.name);
    values.set(key, { email: previous && previous.lastUsed > record.lastUsed ? previous.email : email,
      name: name && (!previous || !previous.name || record.lastUsed >= previous.lastUsed) ? name : previous?.name || '',
      lastUsed: Math.max(previous?.lastUsed || 0, record.lastUsed) });
  }
  return Array.from(values.values()).sort((a, b) => b.lastUsed - a.lastUsed || a.email.localeCompare(b.email))
    .slice(0, RECIPIENT_HISTORY_LIMIT);
}

export function knownRecipientNames(messages: JmapEmail[]): JmapAddress[] {
  const values = new Map<string, JmapAddress>();
  for (const mail of messages.slice().sort((a, b) => b.receivedAt - a.receivedAt)) {
    for (const address of mail.from.concat(mail.replyTo || [], mail.to, mail.cc || [])) {
      if (address.name && !values.has(addressKey(address.email))) { values.set(addressKey(address.email), address); }
    }
  }
  return Array.from(values.values());
}

// Called only for a confirmed submission; the original Swift SMTP boundary
// validates the actual plain addresses. Labels come from this account's cache.
export function sentRecipients(fields: RecipientFields, names: JmapAddress[], when: number): RecipientRecord[] {
  const labels = new Map<string, string>();
  names.forEach(address => { if (address.name) { labels.set(addressKey(address.email), cleanName(address.name)); } });
  return mergeRecipients([], [fields.to, fields.cc, fields.bcc].flatMap(value => value.split(/[;,]/))
    .map(email => ({ email: email.trim(), name: labels.get(addressKey(email)) || '', lastUsed: when })));
}

export function cachedSentRecipients(messages: JmapEmail[], boxes: JmapMailbox[]): RecipientRecord[] {
  const sent = new Set(boxes.filter(box => box.role === 'sent' && !box.id.startsWith('local_')).map(box => box.id));
  const result: RecipientRecord[] = [];
  for (const mail of messages) {
    if (mail.keywords.includes('$draft') || (!mail.id.startsWith('local_sent_') && !mail.mailboxIds.some(id => sent.has(id)))) { continue; }
    for (const address of mail.to.concat(mail.cc || [])) {
      result.push({ email: address.email, name: address.name, lastUsed: mail.receivedAt });
    }
  }
  return mergeRecipients([], result);
}

export function recipientToken(value: string, caret: number = value.length): RecipientToken {
  const position = Math.max(0, Math.min(value.length, caret));
  let start = position, end = position;
  while (start > 0 && value[start - 1] !== ',' && value[start - 1] !== ';') { start--; }
  while (end < value.length && value[end] !== ',' && value[end] !== ';') { end++; }
  return { start, end, query: value.slice(start, end).trim().toLowerCase() };
}

export function recipientSuggestions(history: RecipientRecord[], value: string, caret: number, otherFields: string[]): RecipientRecord[] {
  const token = recipientToken(value, caret), used = new Set(otherFields.concat(value.slice(0, token.start), value.slice(token.end))
    .flatMap(field => field.split(/[;,]/)).map(addressKey));
  return history.filter(record => !used.has(addressKey(record.email)) &&
    (record.email.toLowerCase().includes(token.query) || record.name.toLowerCase().includes(token.query)))
    .slice(0, 5);
}

export function completeRecipient(value: string, caret: number, email: string): string {
  const token = recipientToken(value, caret);
  const prefix = value.slice(0, token.start), suffix = value.slice(token.end);
  return `${prefix}${prefix && !/\s$/.test(prefix) ? ' ' : ''}${email}${suffix}`;
}
