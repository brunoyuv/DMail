// MPL-2.0: https://mozilla.org/MPL/2.0/
import { JmapEmail } from './jmap/JmapClient';

function compact(value: string): string {
  return Array.from(value.slice(0, 200000).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '')
    .replace(/\s+/g, ' ').trim()).slice(0, 180).join('');
}

function omitNonContent(html: string): string {
  const pieces: string[] = [];
  const opening = /<(head|style|script|template)\b/gi;
  let offset = 0, match: RegExpExecArray | null;
  while ((match = opening.exec(html)) !== null) {
    const tagEnd = html.indexOf('>', opening.lastIndex);
    // No later opener can complete a tag when the remaining suffix has no '>'.
    // Preserve it once instead of restarting a greedy search at every '<'.
    if (tagEnd < 0) { break; }
    const closing = new RegExp(`<\\/${match[1]}\\s*>`, 'gi');
    closing.lastIndex = tagEnd + 1;
    const end = closing.exec(html) === null ? html.length : closing.lastIndex;
    pieces.push(html.slice(offset, match.index), ' ');
    offset = end; opening.lastIndex = end;
  }
  pieces.push(html.slice(offset));
  return pieces.join('');
}

function stripTags(html: string): string {
  const pieces: string[] = [];
  let offset = 0;
  while (offset < html.length) {
    const start = html.indexOf('<', offset);
    if (start < 0) { break; }
    const end = html.indexOf('>', start + 1);
    if (end < 0) { break; }
    pieces.push(html.slice(offset, start), ' ');
    offset = end + 1;
  }
  pieces.push(html.slice(offset));
  return pieces.join('');
}

// This produces plain text for a native Text row; it never renders HTML or
// resolves a URL. Bound work on already-downloaded content and omit non-content
// elements so stylesheet/script text cannot become an inbox summary.
function htmlExcerpt(html: string): string {
  const source = html.slice(0, 200000).replace(/<!--[\s\S]*?(?:-->|$)/g, ' ');
  const text = stripTags(omitNonContent(source))
    .replace(/&(#(?:x[0-9a-f]+|[0-9]+)|amp|lt|gt|quot|apos|nbsp|ensp|emsp|ndash|mdash|hellip);/gi,
      (match: string, entity: string): string => {
        const key = entity.toLowerCase();
        if (key.startsWith('#')) {
          const value = key.startsWith('#x') ? parseInt(key.slice(2), 16) : parseInt(key.slice(1), 10);
          return value > 0 && value <= 0x10ffff && !(value >= 0xd800 && value <= 0xdfff) ? String.fromCodePoint(value) : ' ';
        }
        const values: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
          ensp: ' ', emsp: ' ', ndash: '–', mdash: '—', hellip: '…' };
        return values[key] ?? match;
      });
  return compact(text);
}

export function messagePreview(mail: JmapEmail): string {
  const supplied = compact(mail.preview);
  if (supplied) { return supplied; }
  const plain = compact(mail.textBody ?? '');
  return plain || htmlExcerpt(mail.htmlBody ?? '');
}
