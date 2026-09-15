// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { JmapEmail } from './jmap/JmapClient';

// Callers supply one account's records (MailCache.cachedMessages enforces this).
// Subjects are deliberately irrelevant: replies may be renamed, and unrelated
// messages often have identical subjects. Missing ancestors still connect replies.
const HEADER_LIMIT = 256;
function messageIds(values: string[] | undefined): string[] {
  const result: string[] = [];
  for (const value of (values ?? []).slice(0, HEADER_LIMIT)) {
    if (value.length > 16384) { continue; }
    const enclosed = value.match(/<[^<>\s]+@[^<>\s]+>/g);
    const tokens = enclosed ?? [value.trim()];
    for (const token of tokens) {
      const id = token.startsWith('<') && token.endsWith('>') ? token.slice(1, -1) : token;
      // Ignore truncated, control-containing or malformed header fragments.
      if (!/^[^\x00-\x20\x7f<>@]+@[^\x00-\x20\x7f<>@]+$/.test(id) || id.length > 998) { continue; }
      const at = id.lastIndexOf('@');
      const normalized = id.slice(0, at + 1) + id.slice(at + 1).toLowerCase();
      if (!result.includes(normalized)) { result.push(normalized); }
      if (result.length === HEADER_LIMIT) { return result; }
    }
  }
  return result;
}

// A copied/moved message or a local Sent copy can acquire another protocol ID.
// Message-specific preferences still belong to the same MIME message.
export function stableMessageKey(mail: JmapEmail): string {
  const ids = messageIds(mail.messageIds);
  return ids.length === 1 ? `message:${ids[0]}` : `copy:${mail.cachedSourceId || mail.id}`;
}
function compareMail(a: JmapEmail, b: JmapEmail): number {
  return a.receivedAt - b.receivedAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}
function bodyQuality(mail: JmapEmail): number {
  const hasBody = mail.cachedBodyAvailable === true || typeof mail.textBody === 'string' || typeof mail.htmlBody === 'string';
  return (hasBody ? 4 : 0) + (!mail.bodyTruncated ? 2 : 0) + (!mail.bodyEncodingProblem ? 1 : 0);
}
class MessageGraph {
  private parents: number[] = [];
  constructor(size: number) { for (let index = 0; index < size; index++) { this.parents.push(index); } }
  root(index: number): number {
    let current = index;
    while (this.parents[current] !== current) {
      this.parents[current] = this.parents[this.parents[current]]; current = this.parents[current];
    }
    return current;
  }
  join(first: number, second: number): void {
    const a = this.root(first), b = this.root(second);
    if (a !== b) { this.parents[Math.max(a, b)] = Math.min(a, b); }
  }
}
function connected(candidates: JmapEmail[]): JmapEmail[][] {
  const graph = new MessageGraph(candidates.length);
  const identities = new Map<string, number>();
  candidates.forEach((mail, index) => {
    const ids = messageIds(mail.messageIds).concat(messageIds(mail.inReplyTo), messageIds(mail.references));
    const keys = ids.map(id => `message:${id}`);
    // IMAP currently supplies the message's own opaque ID as threadId. That
    // placeholder is not evidence that another message belongs to its thread.
    if (mail.threadId && mail.threadId !== mail.id) { keys.push(`thread:${mail.threadId}`); }
    keys.push(`copy:${mail.id}`);
    for (const key of keys) {
      const earlier = identities.get(key);
      if (earlier === undefined) { identities.set(key, index); } else { graph.join(earlier, index); }
    }
  });
  const groups = new Map<number, JmapEmail[]>();
  candidates.forEach((mail, index) => {
    const root = graph.root(index), group = groups.get(root) ?? [];
    group.push(mail); groups.set(root, group);
  });
  return Array.from(groups.values());
}
function distinctCopies(messages: JmapEmail[], anchor?: JmapEmail): JmapEmail[] {
  const graph = new MessageGraph(messages.length), identities = new Map<string, number>();
  messages.forEach((mail, index) => {
    const keys = messageIds(mail.messageIds).map(id => `message:${id}`).concat(`copy:${mail.id}`);
    for (const key of keys) {
      const earlier = identities.get(key);
      if (earlier === undefined) { identities.set(key, index); } else { graph.join(earlier, index); }
    }
  });
  const chosen = new Map<number, JmapEmail>();
  messages.forEach((mail, index) => {
    const key = graph.root(index), previous = chosen.get(key);
    if (mail === anchor || (!previous || previous !== anchor && (bodyQuality(mail) > bodyQuality(previous) ||
      (bodyQuality(mail) === bodyQuality(previous) && compareMail(mail, previous) < 0)))) { chosen.set(key, mail); }
  });
  return Array.from(chosen.values()).sort(compareMail);
}

export function conversationGroups(candidates: JmapEmail[]): JmapEmail[][] {
  return connected(candidates).map(group => distinctCopies(group))
    .sort((first, second) => compareMail(first[0], second[0]));
}
export function conversationMessages(anchor: JmapEmail, candidates: JmapEmail[]): JmapEmail[] {
  // Include the current reader even if it has not been cached yet. Resolve the
  // group before deduplication; retain the actual selected copy for actions.
  const group = connected(candidates.concat(anchor)).find(messages => messages.some(mail => mail === anchor));
  return distinctCopies(group ?? [anchor], anchor);
}
