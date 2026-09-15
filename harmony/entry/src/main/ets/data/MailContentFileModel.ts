// MPL-2.0: https://mozilla.org/MPL/2.0/
export type MailContentKind = 'text' | 'html';
export interface MailContentFileStore {
  write(accountId: string, kind: MailContentKind, content: string): Promise<string>;
  read(accountId: string, reference: string, maxCharacters: number): Promise<string>;
  forgetAccount(accountId: string): Promise<void>;
  prune(): Promise<void>;
}

export function mailContentAccountValid(accountId: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(accountId);
}

export function mailContentReference(reference: string, kind?: MailContentKind): boolean {
  const parts = reference.split('/');
  if (parts.length !== 2 || !mailContentAccountValid(parts[0]) ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(txt|html)$/.test(parts[1])) { return false; }
  return kind === undefined || parts[1].endsWith(kind === 'text' ? '.txt' : '.html');
}

export function mailContentReferenceValid(accountId: string, reference: string, kind?: MailContentKind): boolean {
  return mailContentAccountValid(accountId) && mailContentReference(reference, kind) && reference.startsWith(`${accountId}/`);
}
