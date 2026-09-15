// MPL-2.0: https://mozilla.org/MPL/2.0/

export function htmlContentInset(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(40, Math.round(value))) : 20;
}

function escapeText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Link only explicit web URLs and escape both displayed text and attributes.
function linkedText(text: string): string {
  const links = /https?:\/\/[^\s<>"'`\\]+/gi;
  let output = '', offset = 0;
  let match: RegExpExecArray | null;
  while ((match = links.exec(text)) !== null) {
    if (match[0].length > 8192) { continue; }
    let url = match[0].replace(/[.,;:!?]+$/, '');
    let excess = (url.match(/\)/g) || []).length - (url.match(/\(/g) || []).length;
    let end = url.length;
    while (excess > 0 && end > 0 && url[end - 1] === ')') { end--; excess--; }
    url = url.slice(0, end);
    if (!/^https?:\/\/[^/?#@]+(?:[/?#]|$)/i.test(url)) { continue; }
    output += escapeText(text.slice(offset, match.index)) + `<a href="${escapeText(url)}" target="_self">${escapeText(url)}</a>`;
    offset = match.index + url.length;
  }
  return output + escapeText(text.slice(offset));
}

// Plain mail remains escaped text, with explicit web links and quote markers.
export function plainTextMailHtml(text: string): string {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let html = '<div class="tb-plain-text">';
  let depth = 0;
  for (let index = 0; index < lines.length; index++) {
    const quote = /^[ \t]*((?:>[ \t]?)+)(.*)$/.exec(lines[index]);
    const nextDepth = quote ? (quote[1].match(/>/g) || []).length : 0;
    while (depth > nextDepth) { html += '</blockquote>'; depth--; }
    while (depth < nextDepth) { html += '<blockquote>'; depth++; }
    html += linkedText(quote ? quote[2] : lines[index]);
    if (index < lines.length - 1) { html += '\n'; }
  }
  while (depth > 0) { html += '</blockquote>'; depth--; }
  return `${html}</div>`;
}

class QuoteRange {
  start: number;
  openEnd: number;
  end: number = 0;
  wrapper: boolean;
  parent: number = -1;
  level: number = 1;
  constructor(start: number, openEnd: number, wrapper: boolean) {
    this.start = start; this.openEnd = openEnd; this.wrapper = wrapper;
  }
}

class OpenMailTag {
  name: string;
  quoteIndex: number;
  constructor(name: string, quoteIndex: number) { this.name = name; this.quoteIndex = quoteIndex; }
}

class MailSourceInsert {
  offset: number;
  order: number;
  text: string;
  constructor(offset: number, order: number, text: string) { this.offset = offset; this.order = order; this.text = text; }
}

function isQuoteWrapper(tag: string, name: string): boolean {
  if (name !== 'div') { return false; }
  const attributes = /\s+([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/gi;
  let attribute: RegExpExecArray | null;
  while ((attribute = attributes.exec(tag)) !== null) {
    if (attribute[1].toLowerCase() === 'class') {
      return /(?:^|\s)(?:gmail_quote|yahoo_quoted|protonmail_quote)(?:\s|$)/i.test(attribute[2] ?? attribute[3] ?? attribute[4] ?? '');
    }
  }
  return false;
}

// Match original source ranges rather than rebuilding sender HTML. Only a
// complete, explicit quote element can be folded; heuristic reply headers and
// unmatched tags never consume the author's following paragraphs.
export function foldMailQuotes(html: string, showLabel: string = 'Show quoted text', hideLabel: string = 'Hide quoted text'): string {
  const ranges: QuoteRange[] = [];
  const stack: OpenMailTag[] = [];
  const openPositions = new Map<string, number[]>();
  const tags = /<!--[\s\S]*?(?:-->|$)|<\/?[a-z][a-z0-9:-]*\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi;
  let rawText = '';
  let token: RegExpExecArray | null;
  while ((token = tags.exec(html)) !== null) {
    const tag = token[0];
    if (tag.startsWith('<!--')) { continue; }
    const named = /^<(\/)?([a-z][a-z0-9:-]*)/i.exec(tag);
    if (!named) { continue; }
    const name = named[2].toLowerCase();
    const closing = named[1] === '/';
    if (rawText !== '') {
      if (closing && name === rawText) { rawText = ''; }
      continue;
    }
    if (!closing && /^(?:script|style|textarea|title|xmp|plaintext)$/.test(name)) { rawText = name; continue; }
    if (closing) {
      const positions = openPositions.get(name);
      if (positions && positions.length > 0) {
        const match = positions[positions.length - 1];
        const quoteIndex = stack[match].quoteIndex;
        if (quoteIndex >= 0) { ranges[quoteIndex].end = tags.lastIndex; }
        // Every open element is removed at most once. Repeated unmatched
        // closing tags must not rescan a deeply nested newsletter each time.
        while (stack.length > match) {
          const removed = stack.pop()!;
          const remaining = openPositions.get(removed.name)!;
          remaining.pop();
          if (remaining.length === 0) { openPositions.delete(removed.name); }
        }
      }
    } else if (!/^(?:area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/.test(name)) {
      const wrapper = isQuoteWrapper(tag, name);
      const quoteIndex = name === 'blockquote' || wrapper ? ranges.length : -1;
      if (quoteIndex >= 0) { ranges.push(new QuoteRange(token.index, tags.lastIndex, wrapper)); }
      const positions = openPositions.get(name) || [];
      positions.push(stack.length); openPositions.set(name, positions);
      stack.push(new OpenMailTag(name, quoteIndex));
    }
  }
  const complete = ranges.filter((range: QuoteRange): boolean => range.end > range.openEnd);
  const ancestors: number[] = [];
  for (let index = 0; index < complete.length; index++) {
    const range = complete[index];
    while (ancestors.length > 0 && complete[ancestors[ancestors.length - 1]].end <= range.start) { ancestors.pop(); }
    if (ancestors.length > 0) {
      range.parent = ancestors[ancestors.length - 1];
      const parent = complete[range.parent];
      // Gmail's wrapper and its immediate blockquote describe one quote level.
      range.level = parent.level + (parent.wrapper && !range.wrapper ? 0 : 1);
    }
    ancestors.push(index);
  }
  const inserts: MailSourceInsert[] = [];
  for (const range of complete) {
    if (range.parent < 0) { inserts.push(new MailSourceInsert(range.end, 0, '</details>')); }
    const attribute = ` data-tb-quote-level="${((range.level - 1) % 3) + 1}"`;
    inserts.push(new MailSourceInsert(range.openEnd - 1, 1, attribute));
    if (range.parent < 0) {
      const disclosure = `<details class="tb-mail-quote"><summary><span class="tb-quote-show">${escapeText(showLabel)}</span><span class="tb-quote-hide">${escapeText(hideLabel)}</span></summary>`;
      inserts.push(new MailSourceInsert(range.start, 2, disclosure));
    }
  }
  inserts.sort((left: MailSourceInsert, right: MailSourceInsert): number => left.offset - right.offset || left.order - right.order);
  let result = '', offset = 0;
  for (const insert of inserts) {
    result += html.slice(offset, insert.offset) + insert.text;
    offset = insert.offset;
  }
  return result + html.slice(offset);
}

// This is a presentation helper, not a sanitizer. ArkWeb's disabled scripting,
// resource interception and the leading CSP remain the security boundaries.
function pictureReferences(html: string): string {
  return html.replace(/&#(x[0-9a-f]+|[0-9]+);?/gi, (_match: string, value: string): string => {
    const code = value[0].toLowerCase() === 'x' ? parseInt(value.slice(1), 16) : parseInt(value, 10);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  }).replace(/&(colon|sol|quot|apos|tab|newline);/gi, (_match: string, name: string): string => {
    if (name.toLowerCase() === 'colon') { return ':'; }
    if (name.toLowerCase() === 'sol') { return '/'; }
    if (name.toLowerCase() === 'quot') { return '"'; }
    if (name.toLowerCase() === 'apos') { return "'"; }
    return ' ';
  });
}

function hasRemoteCssPictures(css: string): boolean {
  const source = css.replace(/\/\*[\s\S]*?(?:\*\/|$)/g, '');
  if (/url\s*\(\s*["']?\s*(?:https?:)?\/\//i.test(source)) { return true; }
  const imageSets = /(?:-webkit-)?image-set\s*\(/gi;
  let match: RegExpExecArray | null;
  while ((match = imageSets.exec(source)) !== null) {
    let depth = 1, index = imageSets.lastIndex;
    // String candidates are URLs too. Respect strings and nested type()/url()
    // arguments so a later candidate is not lost at their first closing ')'.
    while (index < source.length && depth > 0) {
      const character = source[index++];
      if (character === '"' || character === "'") {
        const start = index;
        while (index < source.length && source[index] !== character) {
          if (source[index] === '\\') { index++; }
          index++;
        }
        if (index >= source.length) { break; }
        if (depth === 1 && /^\s*(?:https?:)?\/\//i.test(source.slice(start, index))) { return true; }
        index++;
      } else if (character === '(') { depth++; }
      else if (character === ')') { depth--; }
    }
    imageSets.lastIndex = index;
  }
  return false;
}

export function hasRemotePictures(html: string): boolean {
  // Decode attribute values after tokenizing: escaped quotes inside style=""
  // are CSS syntax, not delimiters of the surrounding HTML attribute.
  const source = html.replace(/<!--[\s\S]*?(?:-->|$)/g, '')
    .replace(/<script\b(?:"[^"]*"|'[^']*'|[^'">])*?>[\s\S]*?(?:<\/script\s*>|$)/gi, '');
  // Inspect every srcset candidate, including a remote candidate after a CID
  // or data image. Ordinary links must not make the picture control appear.
  const tags = source.match(/<[a-z][a-z0-9:-]*\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi) || [];
  for (const tag of tags) {
    const element = /^<([a-z][a-z0-9:-]*)/i.exec(tag)![1].toLowerCase();
    const attributes = /\s+([a-z_:][a-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
    let attribute: RegExpExecArray | null;
    while ((attribute = attributes.exec(tag)) !== null) {
      const name = attribute[1].toLowerCase();
      const value = pictureReferences(attribute[2] ?? attribute[3] ?? attribute[4] ?? '');
      if (name === 'style' && hasRemoteCssPictures(value)) { return true; }
      const imageAttribute = /^(?:img|source|body|table|td|th|div)$/.test(element) && /^(?:src|srcset|background)$/.test(name);
      const svgImageAttribute = element === 'image' && /^(?:href|xlink:href)$/.test(name);
      if ((imageAttribute || svgImageAttribute) && /(?:^|[\s,])(?:https?:)?\/\//i.test(value)) { return true; }
    }
  }
  const styles = /<style\b(?:"[^"]*"|'[^']*'|[^'">])*?>([\s\S]*?)<\/style\s*>/gi;
  let style: RegExpExecArray | null;
  while ((style = styles.exec(source)) !== null) {
    // HTML does not decode character references within style's raw text.
    if (hasRemoteCssPictures(style[1])) { return true; }
  }
  return false;
}

function fitTableWidths(html: string): string {
  return html.replace(/<table\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi, (tag: string): string => {
    const style = /\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i.exec(tag);
    const declarations = style ? (style[1] ?? style[2] ?? style[3]) : '';
    const widths = declarations.match(/(?:^|;)\s*width\s*:[^;]*/gi) || [];
    const importantWidths = widths.filter((value: string): boolean => /!important\s*$/i.test(value));
    const effectiveWidths = importantWidths.length > 0 ? importantWidths : widths;
    const cssWidth = /(?:^|;)\s*width\s*:\s*(\d+(?:\.\d+)?)px\s*(?:!important\s*)?$/i.exec(effectiveWidths[effectiveWidths.length - 1] || '');
    const width = /\swidth\s*=\s*(?:"(\d+(?:\.\d+)?)"|'(\d+(?:\.\d+)?)'|(\d+(?:\.\d+)?)(?=\s|>))/i.exec(tag);
    // Keep percentages, authored column widths, and small signature tables.
    // An explicit CSS width is authoritative over the legacy HTML attribute.
    if (widths.length > 0 && !cssWidth) { return tag; }
    const pixels = cssWidth ? Number(cssWidth[1]) : width ? Number(width[1] ?? width[2] ?? width[3]) : 0;
    if (!Number.isFinite(pixels) || pixels <= 0) { return tag; }
    const fitted = `${declarations}${declarations.trim().endsWith(';') || declarations === '' ? '' : ';'}width:min(100%,${pixels}px)!important`;
    if (style) {
      const quote = style[1] !== undefined ? '"' : "'";
      return tag.replace(style[0], ` style=${quote}${fitted}${quote}`);
    }
    return `${tag.slice(0, -1)} style="${fitted}">`;
  });
}

// ArkWeb receives taps in this view so the native interceptor can open the
// system browser. A sender's _blank/named window must not bypass that path.
function browserMailLinks(html: string): string {
  const tokens = /<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title)\b(?:"[^"]*"|'[^']*'|[^'">])*?>[\s\S]*?(?:<\/\1\s*>|$)|<[a-z][a-z0-9:-]*\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi;
  return html.replace(tokens, (tag: string): string => {
    if (!/^<(?:a|area)\b/i.test(tag)) { return tag; }
    const attributes = /\s+([a-z_:][a-z0-9_:.-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/gi;
    const cleaned = tag.replace(attributes, (attribute: string, name: string): string => {
      return /^(?:target|download)$/i.test(name) ? '' : attribute;
    });
    return cleaned.replace(/\s*\/?>(?=$)/, ' target="_self">');
  });
}

export function prepareMailHtml(html: string, showQuoteLabel: string = 'Show quoted text', hideQuoteLabel: string = 'Hide quoted text'): string {
  return foldMailQuotes(fitTableWidths(browserMailLinks(html).replace(/<meta\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi, '')), showQuoteLabel, hideQuoteLabel);
}

export function mailDocument(html: string, remoteImages: boolean, contentInset: number = 20,
  showQuoteLabel: string = 'Show quoted text', hideQuoteLabel: string = 'Hide quoted text'): string {
  return preparedMailDocument(prepareMailHtml(html, showQuoteLabel, hideQuoteLabel), remoteImages, contentInset);
}

export function preparedMailDocument(body: string, remoteImages: boolean, contentInset: number = 20): string {
  const inset = htmlContentInset(contentInset);
  const images = remoteImages ? 'data: https: http:' : 'data:';
  const policy = `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src ${images}; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'; media-src 'none'`;
  // Sender styles follow these defaults. ArkWeb adapts authored colors in dark
  // mode, while this media query provides readable quote levels. Do not declare
  // a global color-scheme: dark: that would disable ArkWeb's adaptation for
  // sender-authored white backgrounds. Theme changes need no document reload.
  const styles = `
html{width:100%!important;min-width:0!important;box-sizing:border-box}
body{width:auto!important;min-width:0!important;max-width:100%!important;margin:0 ${inset}px ${inset}px!important;overflow-wrap:anywhere;font:16px/1.55 sans-serif}
*,*::before,*::after{box-sizing:border-box}
img,svg{max-width:100%!important;height:auto;vertical-align:middle}
table{max-width:100%!important;min-width:0!important}
td,th{min-width:0!important;overflow-wrap:anywhere!important;word-wrap:break-word}
div,p,section,article,main{max-width:100%!important;min-width:0!important}
.tb-plain-text{white-space:pre-wrap;font-size:17px;line-height:28px}
.tb-mail-quote{margin:12px 0;max-width:100%;min-width:0}
.tb-mail-quote>summary{display:list-item!important;cursor:pointer;min-height:44px;padding:10px 0;color:#3975b5!important;font:14px/24px sans-serif;white-space:normal;list-style-position:inside}
.tb-mail-quote>summary .tb-quote-hide{display:none!important}
.tb-mail-quote[open]>summary .tb-quote-hide{display:inline!important}
.tb-mail-quote[open]>summary .tb-quote-show{display:none!important}
[data-tb-quote-level]{margin:8px 0!important;padding:0!important}
blockquote[data-tb-quote-level]{padding-inline-start:12px!important;border:0!important;border-inline-start:2px solid currentColor!important}
[data-tb-quote-level] *{color:inherit!important}
[data-tb-quote-level="1"]{color:#3474ad!important}
[data-tb-quote-level="2"]{color:#3d8062!important}
[data-tb-quote-level="3"]{color:#8655a0!important}
@media(prefers-color-scheme:dark){
html,body{background-color:#191a1b;color:#e5e7eb}
.tb-mail-quote>summary{color:#82b6eb!important}
[data-tb-quote-level="1"]{color:#82b6eb!important}
[data-tb-quote-level="2"]{color:#80c5a3!important}
[data-tb-quote-level="3"]{color:#bf9add!important}
}
pre{max-width:100%!important;white-space:pre-wrap!important;overflow-wrap:anywhere!important;word-break:break-word}
iframe,object,embed,form,input,button,textarea,select,video,audio{display:none!important}`;
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${styles}</style></head><body>${body}</body></html>`;
}
