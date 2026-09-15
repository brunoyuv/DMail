// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { prepareMailHtml } from './HtmlDocument';
import { mailHtmlAttributes, replaceMailHtmlTokens } from './HtmlTokens';
import { HTML_ATTRIBUTE_ENTITIES, HTML_LEGACY_ATTRIBUTE_ENTITIES } from './HtmlEntities';

export interface StaticMailPicture { id: string; url: string; }
export interface StaticMailPicturePlan { html: string; pictures: StaticMailPicture[]; overflow: boolean; }

interface Edit { start: number; end: number; text: string; }
interface CssString { end: number; contentEnd: number; closed: boolean; }

const MAX_PICTURES = 256;
const MAX_URL_LENGTH = 8192;

function space(character: string): boolean { return character === ' ' || character === '\t' || character === '\n' || character === '\r' || character === '\f'; }
function applyEdits(source: string, edits: Edit[]): string {
  if (edits.length === 0) { return source; }
  const parts: string[] = []; let offset = 0;
  for (const edit of edits) { parts.push(source.slice(offset, edit.start), edit.text); offset = edit.end; }
  parts.push(source.slice(offset)); return parts.join('');
}

// Decode HTML5 attribute entities before interpreting URLs/CSS. Unknown named
// references stay authored; a legacy reference without ';' cannot consume the
// start of an alphanumeric name or an equals sign in a signed query parameter.
function attributeText(source: string): string {
  return source.replace(/&(?:#(x[0-9a-f]+|[0-9]+);?|([a-z][a-z0-9]{1,31});?)/gi,
    (match: string, numeric: string | undefined, named: string | undefined, offset: number): string => {
      if (numeric) {
        let code = numeric[0].toLowerCase() === 'x' ? parseInt(numeric.slice(1), 16) : parseInt(numeric, 10);
        const c1 = [0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039,
          0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc,
          0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178];
        if (code >= 0x80 && code <= 0x9f) { code = c1[code - 0x80]; }
        return code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : '\ufffd';
      }
      if (!match.endsWith(';') && (!HTML_LEGACY_ATTRIBUTE_ENTITIES.has(named || '') || /[a-z0-9=]/i.test(source[offset + match.length] || ''))) { return match; }
      return HTML_ATTRIBUTE_ENTITIES.get(named || '') ?? match;
    });
}

function encodedAttribute(value: string, quote: string): string {
  const result = value.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  return quote === "'" ? result.replace(/'/g, '&#39;') : result.replace(/"/g, '&quot;');
}

function cssEscapeEnd(source: string, start: number): number {
  let end = start + 1;
  if (source[end] === '\r' && source[end + 1] === '\n') { return end + 2; }
  if (!/[0-9a-f]/i.test(source[end] || '')) { return Math.min(source.length, end + 1); }
  let digits = 0;
  while (end < source.length && digits < 6 && /[0-9a-f]/i.test(source[end])) { end++; digits++; }
  if (space(source[end])) { if (source[end] === '\r' && source[end + 1] === '\n') { end++; } end++; }
  return end;
}

function cssText(source: string): string {
  const parts: string[] = []; let offset = 0;
  for (let index = 0; index < source.length; index++) {
    if (source[index] !== '\\') { continue; }
    const end = cssEscapeEnd(source, index), escaped = source.slice(index + 1, end);
    let value = '';
    if (/^[0-9a-f]/i.test(escaped)) {
      const code = parseInt(escaped, 16);
      value = code > 0 && code <= 0x10ffff && !(code >= 0xd800 && code <= 0xdfff) ? String.fromCodePoint(code) : '\ufffd';
    } else if (!/^[\r\n\f]/.test(escaped)) { value = escaped; }
    parts.push(source.slice(offset, index), value); offset = end; index = end - 1;
  }
  parts.push(source.slice(offset)); return parts.join('');
}

function cssString(source: string, start: number): CssString {
  const quote = source[start]; let index = start + 1;
  while (index < source.length && source[index] !== quote) {
    if (source[index] === '\\') { index = cssEscapeEnd(source, index); }
    else if (source[index] === '\n' || source[index] === '\r' || source[index] === '\f') { return { end: index, contentEnd: index, closed: false }; }
    else { index++; }
  }
  return { end: index < source.length ? index + 1 : index, contentEnd: index, closed: index < source.length };
}

class PicturePlanner {
  pictures: StaticMailPicture[] = [];
  overflow: boolean = false;
  private byUrl: Map<string, StaticMailPicture> = new Map();
  private resourcePrefix: string;

  constructor(resourcePrefix: string) {
    this.resourcePrefix = resourcePrefix.length <= 256 && /^https:\/\/mail\.invalid\/picture\/(?:[a-z0-9_-]+\/)*$/i.test(resourcePrefix) ?
      resourcePrefix : 'https://mail.invalid/picture/';
  }

  reference(source: string): string | null {
    let value = source.trim();
    if (value.startsWith('//')) { value = `https:${value}`; }
    if (!/^https?:\/\//i.test(value)) { return null; }
    if (value.length > MAX_URL_LENGTH) { this.overflow = true; return null; }
    if (/[\u0000-\u001f\u007f\\]/.test(value)) { return null; }
    // Path, query order, repeated slashes and percent escapes may be signed.
    // Normalize only transport-equivalent authority spelling and the fragment.
    const match = /^(https?):\/\/([^/?#]+)([\s\S]*)$/i.exec(value);
    if (!match || /[@\s]/.test(match[2])) { return null; }
    const scheme = match[1].toLowerCase();
    let authority = match[2].toLowerCase();
    if (scheme === 'https') { authority = authority.replace(/:443$/, ''); }
    else { authority = authority.replace(/:80$/, ''); }
    if (/^mail\.invalid\.?(?::[0-9]+)?$/.test(authority)) { return null; }
    const fragmentStart = match[3].indexOf('#');
    const fragment = fragmentStart < 0 ? '' : match[3].slice(fragmentStart).replace(/[ "'<>`()]/g,
      (character: string): string => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
    let path = fragmentStart < 0 ? match[3] : match[3].slice(0, fragmentStart);
    if (path === '' || path[0] === '?') { path = `/${path}`; }
    // Match browser request spelling for Unicode while retaining existing
    // percent escapes, signed query order and path separators verbatim.
    path = path.replace(/[\ud800-\udbff][\udc00-\udfff]|[ "<>`\u0080-\uffff]/g,
      (character: string): string => encodeURIComponent(character.length === 1 &&
        /[\ud800-\udfff]/.test(character) ? '\ufffd' : character));
    const url = `${scheme}://${authority}${path}`;
    if (url.length > MAX_URL_LENGTH) { this.overflow = true; return null; }
    let resource = this.byUrl.get(url);
    if (!resource) {
      if (this.pictures.length >= MAX_PICTURES) { this.overflow = true; return null; }
      resource = { id: `${this.resourcePrefix}${this.pictures.length}`, url: url };
      this.pictures.push(resource); this.byUrl.set(url, resource);
    }
    return `${resource.id}${fragment}`;
  }
}

function pictureSrcset(source: string, planner: PicturePlanner): string {
  const edits: Edit[] = []; let index = 0;
  while (index < source.length) {
    while (space(source[index]) || source[index] === ',') { index++; }
    const start = index;
    while (index < source.length && !space(source[index])) { index++; }
    let end = index;
    while (end > start && source[end - 1] === ',') { end--; }
    const replacement = planner.reference(source.slice(start, end));
    if (replacement) { edits.push({ start: start, end: end, text: replacement }); }
    if (end !== index) { continue; }
    let depth = 0;
    while (index < source.length) {
      const character = source[index++];
      if (character === '(') { depth++; }
      else if (character === ')') { depth = Math.max(0, depth - 1); }
      else if (character === ',' && depth === 0) { break; }
    }
  }
  return applyEdits(source, edits);
}

function cssNameEnd(source: string, start: number): number {
  let index = start;
  while (index < source.length) {
    if (source[index] === '\\') { index = cssEscapeEnd(source, index); }
    else if (/[a-z0-9_-]/i.test(source[index])) { index++; }
    else { break; }
  }
  return index;
}

// Skip a non-image at-rule without inspecting its strings/functions. Font and
// stylesheet URLs must never enter the image download queue.
function skipAtRule(source: string, start: number, block: boolean): number {
  let index = start, depth = 0;
  while (index < source.length) {
    const character = source[index];
    if (character === '"' || character === "'") { index = cssString(source, index).end; continue; }
    if (source.startsWith('/*', index)) { const end = source.indexOf('*/', index + 2); index = end < 0 ? source.length : end + 2; continue; }
    index++;
    if (character === '{') { if (!block) { return index; } depth++; }
    else if (character === '}' && depth > 0) { if (--depth === 0) { return index; } }
    else if (character === ';' && depth === 0) { return index; }
  }
  return index;
}

function pictureCss(source: string, planner: PicturePlanner): string {
  const edits: Edit[] = [], functions: string[] = []; let index = 0;
  while (index < source.length) {
    const character = source[index];
    if (source.startsWith('/*', index)) { const end = source.indexOf('*/', index + 2); index = end < 0 ? source.length : end + 2; continue; }
    if (character === '@') {
      const end = cssNameEnd(source, index + 1), name = cssText(source.slice(index + 1, end)).toLowerCase();
      index = skipAtRule(source, end, name === 'font-face'); continue;
    }
    if (character === '"' || character === "'") {
      const string = cssString(source, index);
      const parent = functions[functions.length - 1];
      if (string.closed && (parent === 'url' || parent === 'image-set' || parent === '-webkit-image-set')) {
        const replacement = planner.reference(cssText(source.slice(index + 1, string.contentEnd)));
        if (replacement) { edits.push({ start: index + 1, end: string.contentEnd, text: replacement }); }
      }
      index = Math.max(index + 1, string.end); continue;
    }
    if (/[a-z_-]/i.test(character) || character === '\\') {
      const end = cssNameEnd(source, index), name = cssText(source.slice(index, end)).toLowerCase();
      let open = end; while (space(source[open])) { open++; }
      if (source[open] !== '(') { index = end; continue; }
      functions.push(name); index = open + 1;
      if (name === 'url') {
        while (space(source[index])) { index++; }
        if (source[index] === '"' || source[index] === "'") { continue; }
        const start = index; let valid = true, spaces = false;
        while (index < source.length && source[index] !== ')') {
          if (source[index] === '\\') { if (spaces) { valid = false; } index = cssEscapeEnd(source, index); }
          else { if (space(source[index])) { spaces = true; } else if (spaces || source[index] === '"' || source[index] === "'" || source[index] === '(') { valid = false; } index++; }
        }
        if (source[index] === ')' && valid) {
          let close = index; while (close > start && space(source[close - 1])) { close--; }
          const replacement = planner.reference(cssText(source.slice(start, close)));
          if (replacement) { edits.push({ start: start, end: close, text: replacement }); }
        }
      }
      continue;
    }
    if (character === '(') { functions.push(''); }
    else if (character === ')') { functions.pop(); }
    index++;
  }
  return applyEdits(source, edits);
}

export function prepareStaticMailHtml(html: string, showQuoteLabel: string = 'Show quoted text', hideQuoteLabel: string = 'Hide quoted text',
  resourcePrefix: string = 'https://mail.invalid/picture/'): StaticMailPicturePlan {
  const planner = new PicturePlanner(resourcePrefix);
  const prepared = prepareMailHtml(html, showQuoteLabel, hideQuoteLabel);
  const rewritten = replaceMailHtmlTokens(prepared, (token, source: string): string => {
    if (token.kind === 'comment' || token.closing) { return source; }
    if (token.kind === 'raw') {
      if (token.name !== 'style') { return source; }
      const start = token.tagEnd - token.start, end = token.closeStart - token.start;
      return source.slice(0, start) + pictureCss(source.slice(start, end), planner) + source.slice(end);
    }
    const edits: Edit[] = [];
    for (const attribute of mailHtmlAttributes(source)) {
      if (attribute.value === undefined) { continue; }
      const name = attribute.name;
      const image = token.name === 'img' && name === 'src' || token.name === 'image' && (name === 'href' || name === 'xlink:href') ||
        ['body', 'table', 'td', 'th', 'div'].includes(token.name) && name === 'background';
      const srcset = ['img', 'source'].includes(token.name) && name === 'srcset';
      if (!image && !srcset && name !== 'style') { continue; }
      const value = attributeText(attribute.value);
      const replacement = image ? planner.reference(value) : srcset ? pictureSrcset(value, planner) : pictureCss(value, planner);
      if (replacement === null || replacement === value) { continue; }
      const quote = source[attribute.valueStart - 1];
      const quoted = quote === '"' || quote === "'";
      const encoded = encodedAttribute(replacement, quoted ? quote : '"');
      edits.push({ start: attribute.valueStart, end: attribute.valueEnd, text: quoted ? encoded : `"${encoded}"` });
    }
    return applyEdits(source, edits);
  });
  return { html: rewritten, pictures: planner.pictures, overflow: planner.overflow };
}
