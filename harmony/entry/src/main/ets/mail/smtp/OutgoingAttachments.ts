// MPL-2.0: https://mozilla.org/MPL/2.0/
export const OUTGOING_ATTACHMENT_COUNT = 10;
export const OUTGOING_ATTACHMENT_BYTES = 10 * 1024 * 1024;

export interface OutgoingAttachment {
  id: string; name: string; contentType: string; size: number; file: string;
}
export interface SmtpAttachmentData {
  id: string; name: string; contentType: string; size: number; base64: string;
}
export interface SmtpAttachmentInput {
  id: string; name: string; contentType: string; size: number; base64?: string;
}

function utf8Length(value: string): number {
  let count = 0;
  for (let index = 0; index < value.length; index++) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(++index);
      if (!(next >= 0xdc00 && next <= 0xdfff)) { return -1; }
      count += 4;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) { return -1; }
    else { count += unit <= 0x7f ? 1 : unit <= 0x7ff ? 2 : 3; }
  }
  return count;
}

// Drafts retain small opaque file references. Bytes belong only to the explicit
// send operation, never to the database row or a persisted sending snapshot.
export function outgoingAttachmentsValid(value: OutgoingAttachment[] | undefined): boolean {
  if (value === undefined) { return true; }
  if (!Array.isArray(value) || value.length > OUTGOING_ATTACHMENT_COUNT) { return false; }
  const ids: Set<string> = new Set();
  let total = 0;
  for (const attachment of value) {
    if (!attachment || Object.keys(attachment).some(key => !['id', 'name', 'contentType', 'size', 'file'].includes(key)) || typeof attachment.id !== 'string' ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(attachment.id) || ids.has(attachment.id.toLowerCase()) ||
      typeof attachment.name !== 'string' || attachment.name.length === 0 || utf8Length(attachment.name) < 0 ||
      utf8Length(attachment.name) > 512 || /[\u0000-\u001f\u007f]/.test(attachment.name) ||
      typeof attachment.contentType !== 'string' || attachment.contentType.length > 127 ||
      !/^(application|audio|example|font|haptics|image|message|model|text|video)\/[a-z0-9][a-z0-9!#$&^_.+-]*$/i.test(attachment.contentType) ||
      !Number.isSafeInteger(attachment.size) || attachment.size < 0 || attachment.size > OUTGOING_ATTACHMENT_BYTES ||
      typeof attachment.file !== 'string' || attachment.file.length === 0 || attachment.file.length > 512) { return false; }
    total += attachment.size; ids.add(attachment.id.toLowerCase());
    if (total > OUTGOING_ATTACHMENT_BYTES) { return false; }
  }
  return true;
}

export function outgoingAttachmentInput(metadata: OutgoingAttachment[] | undefined, bytes: SmtpAttachmentData[] | undefined,
  validateOnly: boolean): SmtpAttachmentInput[] {
  if (!outgoingAttachmentsValid(metadata)) { throw new Error('Invalid attachment metadata'); }
  const entries = metadata ?? [];
  if (!validateOnly && (bytes?.length ?? 0) !== entries.length) { throw new Error('Attachment bytes are unavailable'); }
  return entries.map((entry: OutgoingAttachment, index: number): SmtpAttachmentInput => {
    const input: SmtpAttachmentInput = { id: entry.id, name: entry.name, contentType: entry.contentType, size: entry.size };
    if (!validateOnly) {
      const data = bytes?.[index];
      if (!data || data.id !== entry.id || data.name !== entry.name || data.contentType !== entry.contentType || data.size !== entry.size ||
        typeof data.base64 !== 'string' || data.base64.length !== Math.ceil(entry.size / 3) * 4 ||
        /[^A-Za-z0-9+/=]/.test(data.base64)) {
        throw new Error('Attachment bytes do not match the draft');
      }
      input.base64 = data.base64;
    }
    return input;
  });
}
