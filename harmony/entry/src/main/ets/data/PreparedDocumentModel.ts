// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { mailContentReference } from './MailContentFileModel';

export interface PreparedDocumentPicture { id: string; url: string; }
export interface PreparedMailDocument {
  version: number;
  messageKey: string;
  bodySavedAt: number;
  savedAt: number;
  html: string;
  pictures: PreparedDocumentPicture[];
}
// Stored records keep either legacy inline HTML or one app-private file
// reference. Reader-facing documents always contain hydrated HTML.
export interface PreparedDocumentRecord {
  version: number;
  messageKey: string;
  bodySavedAt: number;
  savedAt: number;
  html?: string;
  htmlFile?: string;
  pictures: PreparedDocumentPicture[];
}
export interface PreparedDocumentState {
  attempted: boolean;
  document: PreparedMailDocument | null;
  bodySavedAt: number | null;
  failure: '' | 'expired' | 'failed';
}

export const PREPARED_DOCUMENT_VERSION = 1;
export const MAX_PREPARED_HTML = 8 * 1024 * 1024;
export const MAX_PREPARED_PAYLOAD = 16 * 1024 * 1024;

export function preparedDocumentIdentity(accountId: string, messageKey: string): boolean {
  return accountId.length > 0 && accountId.length <= 4096 && messageKey.length > 0 && messageKey.length <= 4096;
}

function timestamp(value: unknown): boolean {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

export function validatePreparedDocument(value: PreparedMailDocument, messageKey: string): void {
  if (!value || typeof value !== 'object' || value.version !== PREPARED_DOCUMENT_VERSION ||
    value.messageKey !== messageKey || !preparedDocumentIdentity('account', messageKey) ||
    !timestamp(value.bodySavedAt) || !timestamp(value.savedAt) ||
    typeof value.html !== 'string' || value.html.length > MAX_PREPARED_HTML ||
    !Array.isArray(value.pictures) || value.pictures.length > 256) {
    throw new Error('Prepared document storage is invalid');
  }
  const ids = new Set<string>(), urls = new Set<string>();
  for (const picture of value.pictures) {
    if (!picture || typeof picture !== 'object' || typeof picture.id !== 'string' ||
      !/^https:\/\/mail\.invalid\/picture\/[A-Za-z0-9/_-]{1,512}$/.test(picture.id) ||
      typeof picture.url !== 'string' || picture.url.length > 8192 ||
      !/^https?:\/\/[^\s\\\/?#@]+(?:[\/?#]|$)/i.test(picture.url) || /[\u0000-\u0020\u007f\\]/.test(picture.url) ||
      ids.has(picture.id) || urls.has(picture.url)) {
      throw new Error('Prepared document storage is invalid');
    }
    ids.add(picture.id); urls.add(picture.url);
  }
}

function validatePreparedRecord(value: PreparedDocumentRecord, messageKey: string): void {
  if (value && typeof value.htmlFile === 'string') {
    // File reads additionally check the exact owning account.
    if (value.html !== undefined || !mailContentReference(value.htmlFile, 'html')) {
      throw new Error('Prepared document storage is invalid');
    }
    validatePreparedDocument({ version: value.version, messageKey: value.messageKey,
      bodySavedAt: value.bodySavedAt, savedAt: value.savedAt, html: '', pictures: value.pictures }, messageKey);
  } else {
    if (value?.htmlFile !== undefined) { throw new Error('Prepared document storage is invalid'); }
    validatePreparedDocument(value as PreparedMailDocument, messageKey);
  }
}

export function encodePreparedRecord(record: PreparedDocumentRecord): string {
  validatePreparedRecord(record, record.messageKey);
  const payload = JSON.stringify(record);
  if (payload.length > MAX_PREPARED_PAYLOAD) { throw new Error('Prepared document storage is invalid'); }
  return payload;
}

export function decodePreparedRecord(payload: string, messageKey: string): PreparedDocumentRecord {
  if (payload.length > MAX_PREPARED_PAYLOAD) { throw new Error('Prepared document storage is invalid'); }
  let record: PreparedDocumentRecord;
  try { record = JSON.parse(payload) as PreparedDocumentRecord; }
  catch (_) { throw new Error('Prepared document storage is invalid'); }
  validatePreparedRecord(record, messageKey); return record;
}

export function encodePreparedDocument(document: PreparedMailDocument): string {
  validatePreparedDocument(document, document.messageKey);
  const payload = JSON.stringify(document);
  if (payload.length > MAX_PREPARED_PAYLOAD) { throw new Error('Prepared document storage is invalid'); }
  return payload;
}

export function decodePreparedDocument(payload: string, messageKey: string): PreparedMailDocument {
  if (payload.length > MAX_PREPARED_PAYLOAD) { throw new Error('Prepared document storage is invalid'); }
  let document: PreparedMailDocument;
  try { document = JSON.parse(payload) as PreparedMailDocument; }
  catch (_) { throw new Error('Prepared document storage is invalid'); }
  validatePreparedDocument(document, messageKey);
  return document;
}
