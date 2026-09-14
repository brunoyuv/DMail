// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/

export enum Folder {
  Inbox = 'Inbox',
  Starred = 'Starred',
  Drafts = 'Drafts',
  Archive = 'Archive'
}

// A platform-neutral subset of upstream Core/Account/Email.swift.
// Local IDs are kept separate from server message and thread identifiers.
export class Mail {
  id: string = '';
  accountId: string = 'demo';
  messageId: string = '';
  threadId: string = '';
  fromName: string = '';
  fromAddress: string = '';
  to: string = '';
  subject: string = '';
  body: string = '';
  receivedAt: number = 0;
  unread: boolean = false;
  starred: boolean = false;
  folder: Folder = Folder.Inbox;
}

export class MailSnapshot {
  version: number = 1;
  messages: Mail[] = [];
}

export function copyMail(source: Mail): Mail {
  const result = new Mail();
  result.id = source.id;
  result.accountId = source.accountId;
  result.messageId = source.messageId;
  result.threadId = source.threadId;
  result.fromName = source.fromName;
  result.fromAddress = source.fromAddress;
  result.to = source.to;
  result.subject = source.subject;
  result.body = source.body;
  result.receivedAt = source.receivedAt;
  result.unread = source.unread;
  result.starred = source.starred;
  result.folder = source.folder;
  return result;
}

export function selectMail(messages: Mail[], folder: Folder, query: string, unreadOnly: boolean): Mail[] {
  const needle = query.trim().toLocaleLowerCase();
  return messages.filter((mail: Mail) => {
    const inFolder = folder === Folder.Starred ? mail.starred && mail.folder !== Folder.Drafts : mail.folder === folder;
    return inFolder && (!unreadOnly || mail.unread) &&
      (needle.length === 0 || [mail.fromName, mail.fromAddress, mail.to, mail.subject, mail.body]
        .join(' ').toLocaleLowerCase().includes(needle));
  }).sort((a: Mail, b: Mail) => b.receivedAt - a.receivedAt);
}

export function updateMail(messages: Mail[], updated: Mail): Mail[] {
  const copy = copyMail(updated);
  if (messages.some((mail: Mail) => mail.id === updated.id)) {
    return messages.map((mail: Mail) => mail.id === updated.id ? copy : mail);
  }
  return [copy, ...messages];
}

export function replyDraft(source: Mail, id: string, now: number): Mail {
  const draft = new Mail();
  draft.id = id;
  draft.folder = Folder.Drafts;
  draft.to = source.fromAddress;
  draft.subject = /^re:/i.test(source.subject) ? source.subject : `Re: ${source.subject}`;
  draft.threadId = source.threadId;
  draft.receivedAt = now;
  return draft;
}

export function hasDraftContent(mail: Mail): boolean {
  return mail.to.trim().length > 0 || mail.subject.trim().length > 0 || mail.body.trim().length > 0;
}

export function validSnapshot(snapshot: MailSnapshot): boolean {
  if (!snapshot || snapshot.version !== 1 || !Array.isArray(snapshot.messages) || snapshot.messages.length > 10000) {
    return false;
  }
  const ids: string[] = [];
  for (const mail of snapshot.messages) {
    if (!mail || typeof mail.id !== 'string' || mail.id.length === 0 || ids.includes(mail.id) ||
      typeof mail.accountId !== 'string' || typeof mail.messageId !== 'string' || typeof mail.threadId !== 'string' ||
      typeof mail.fromName !== 'string' || typeof mail.fromAddress !== 'string' || typeof mail.to !== 'string' ||
      typeof mail.subject !== 'string' || typeof mail.body !== 'string' ||
      typeof mail.receivedAt !== 'number' || !Number.isFinite(mail.receivedAt) ||
      typeof mail.unread !== 'boolean' || typeof mail.starred !== 'boolean' ||
      ![Folder.Inbox, Folder.Archive, Folder.Drafts].includes(mail.folder)) {
      return false;
    }
    ids.push(mail.id);
  }
  return true;
}
