// MPL-2.0: https://mozilla.org/MPL/2.0/
import { OutgoingAttachment, outgoingAttachmentsValid } from '../smtp/OutgoingAttachments';
export { OutgoingAttachment, SmtpAttachmentData, OUTGOING_ATTACHMENT_BYTES, OUTGOING_ATTACHMENT_COUNT } from '../smtp/OutgoingAttachments';

export function outgoingAccountValid(accountId: string): boolean { return /^[A-Za-z0-9_-]{1,128}$/.test(accountId); }
export function outgoingUUIDValid(id: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id);
}
export function outgoingAttachmentReference(accountId: string, draftId: string, attachmentId: string): string {
  if (!outgoingAccountValid(accountId) || !outgoingUUIDValid(draftId) || !outgoingUUIDValid(attachmentId)) {
    throw new Error('Invalid attachment owner');
  }
  return `${accountId}/${draftId.toLowerCase()}/${attachmentId.toLowerCase()}.bin`;
}
export function outgoingAttachmentsOwned(accountId: string, draftId: string, attachments: OutgoingAttachment[] | undefined): boolean {
  if (!outgoingAccountValid(accountId) || !outgoingUUIDValid(draftId) || !outgoingAttachmentsValid(attachments)) { return false; }
  return (attachments ?? []).every((attachment: OutgoingAttachment) =>
    attachment.file === outgoingAttachmentReference(accountId, draftId, attachment.id));
}
export function outgoingAttachmentType(name: string): string {
  const suffix = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  switch (suffix) {
    case 'pdf': return 'application/pdf';
    case 'png': return 'image/png';
    case 'jpg': case 'jpeg': return 'image/jpeg';
    case 'gif': return 'image/gif';
    case 'webp': return 'image/webp';
    case 'svg': return 'image/svg+xml';
    case 'heic': return 'image/heic';
    case 'heif': return 'image/heif';
    case 'txt': return 'text/plain';
    case 'html': case 'htm': return 'text/html';
    case 'csv': return 'text/csv';
    case 'json': return 'application/json';
    case 'xml': return 'application/xml';
    case 'zip': return 'application/zip';
    case 'doc': return 'application/msword';
    case 'docx': return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls': return 'application/vnd.ms-excel';
    case 'xlsx': return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt': return 'application/vnd.ms-powerpoint';
    case 'pptx': return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'eml': return 'message/rfc822';
    case 'mp3': return 'audio/mpeg';
    case 'mp4': return 'video/mp4';
    default: return 'application/octet-stream';
  }
}
