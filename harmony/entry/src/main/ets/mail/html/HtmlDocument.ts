// MPL-2.0: https://mozilla.org/MPL/2.0/

export function htmlContentInset(value: number): number {
  return Number.isFinite(value) ? Math.max(0, Math.min(40, Math.round(value))) : 20;
}

function escapeText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// Plain mail remains text: only explicit leading > quotation markers become
// markup, and every sender-provided character is escaped before presentation.
export function plainTextMailHtml(text: string): string {
  const lines = text.replace(/\r\n?/g, '\n').split('\n');
  let html = '<div class="tb-plain-text">';
  let depth = 0;
  for (let index = 0; index < lines.length; index++) {
    const quote = /^[ \t]*((?:>[ \t]?)+)(.*)$/.exec(lines[index]);
    const nextDepth = quote ? (quote[1].match(/>/g) || []).length : 0;
    while (depth > nextDepth) { html += '</blockquote>'; depth--; }
    while (depth < nextDepth) { html += '<blockquote>'; depth++; }
    html += escapeText(quote ? quote[2] : lines[index]);
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
      let match = stack.length - 1;
      while (match >= 0 && stack[match].name !== name) { match--; }
      if (match >= 0) {
        const quoteIndex = stack[match].quoteIndex;
        if (quoteIndex >= 0) { ranges[quoteIndex].end = tags.lastIndex; }
        stack.splice(match);
      }
    } else if (!/^(?:area|base|br|col|embed|hr|img|input|link|meta|param|source|track|wbr)$/.test(name)) {
      const wrapper = isQuoteWrapper(tag, name);
      const quoteIndex = name === 'blockquote' || wrapper ? ranges.length : -1;
      if (quoteIndex >= 0) { ranges.push(new QuoteRange(token.index, tags.lastIndex, wrapper)); }
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
  }).replace(/&(colon|sol|tab|newline);/gi, (_match: string, name: string): string => {
    if (name.toLowerCase() === 'colon') { return ':'; }
    if (name.toLowerCase() === 'sol') { return '/'; }
    return ' ';
  });
}

export function hasRemotePictures(html: string): boolean {
  const source = pictureReferences(html);
  // Inspect every srcset candidate, including a remote candidate after a CID
  // or data image. Ordinary links must not make the picture control appear.
  const tags = source.match(/<(?:img|source|body|table|td|th|div)\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi) || [];
  for (const tag of tags) {
    const attributes = tag.match(/\s(?:src|srcset|background)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi) || [];
    for (const attribute of attributes) {
      const value = attribute.slice(attribute.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '');
      if (/(?:^|[\s,])(?:https?:)?\/\//i.test(value)) { return true; }
    }
  }
  return /url\s*\(\s*["']?\s*(?:https?:)?\/\//i.test(source);
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

export function mailDocument(html: string, remoteImages: boolean, contentInset: number = 20,
  showQuoteLabel: string = 'Show quoted text', hideQuoteLabel: string = 'Hide quoted text'): string {
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
img,svg{max-width:100%!important;height:auto!important;vertical-align:middle}
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
  const body = foldMailQuotes(fitTableWidths(html.replace(/<meta\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi, '')), showQuoteLabel, hideQuoteLabel);
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${policy}"><meta name="viewport" content="width=device-width, initial-scale=1"><style>${styles}</style></head><body>${body}</body></html>`;
}
