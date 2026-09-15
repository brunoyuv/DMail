// MPL-2.0: https://mozilla.org/MPL/2.0/

export interface HtmlToken {
  start: number;
  end: number;
  tagEnd: number;
  closeStart: number;
  name: string;
  closing: boolean;
  kind: 'tag' | 'comment' | 'raw';
}

export interface HtmlAttribute {
  start: number;
  end: number;
  name: string;
  value: string | undefined;
  valueStart: number;
  valueEnd: number;
}

function letter(code: number): boolean {
  return code >= 65 && code <= 90 || code >= 97 && code <= 122;
}

function nameEnd(source: string, start: number): number {
  let end = start;
  while (end < source.length) {
    const code = source.charCodeAt(end);
    if (space(code) || code === 47 || code === 62) { break; }
    end++;
  }
  return end;
}

function space(code: number): boolean {
  return code === 32 || code === 9 || code === 10 || code === 12 || code === 13;
}

// Keep attribute offsets, including their leading whitespace, for exact source
// edits. Each byte is visited a bounded number of times even on empty attributes
// or very long whitespace runs; quoted values cannot create apparent attributes.
export function mailHtmlAttributes(tag: string): HtmlAttribute[] {
  const result: HtmlAttribute[] = [];
  let index = nameEnd(tag, tag[1] === '/' ? 2 : 1);
  while (index < tag.length) {
    const start = index;
    while (space(tag.charCodeAt(index))) { index++; }
    if (index >= tag.length || tag[index] === '>') { break; }
    if (tag[index] === '/' || tag[index] === '=') { index++; continue; }
    const namedStart = index;
    while (index < tag.length && !space(tag.charCodeAt(index)) && !['=', '/', '>'].includes(tag[index])) { index++; }
    const name = tag.slice(namedStart, index).toLowerCase();
    const namedEnd = index;
    while (space(tag.charCodeAt(index))) { index++; }
    let value: string | undefined;
    let valueStart = index, valueEnd = index;
    if (tag[index] === '=') {
      index++;
      while (space(tag.charCodeAt(index))) { index++; }
      const quote = tag[index] === '"' || tag[index] === "'" ? tag[index++] : '';
      valueStart = index;
      if (quote) {
        while (index < tag.length && tag[index] !== quote) { index++; }
        valueEnd = index; value = tag.slice(valueStart, index);
        if (tag[index] === quote) { index++; }
      } else {
        while (index < tag.length && !space(tag.charCodeAt(index)) && tag[index] !== '>') { index++; }
        valueEnd = index; value = tag.slice(valueStart, index);
      }
    } else { index = namedEnd; }
    result.push({ start: start, end: index, name: name, value: value, valueStart: valueStart, valueEnd: valueEnd });
  }
  return result;
}

function tagEnd(source: string, start: number): number {
  let quote = '';
  for (let index = start; index < source.length; index++) {
    const character = source[index];
    if (quote) {
      if (character === quote) { quote = ''; }
    } else if (character === '"' || character === "'") { quote = character; }
    else if (character === '>') { return index + 1; }
  }
  return -1;
}

// Only source spans are identified: sender markup is never reconstructed.
// After an unfinished tag/quote reaches EOF, keep that suffix verbatim instead
// of restarting at each embedded '<' and repeatedly rescanning the same bytes.
export function mailHtmlTokens(source: string): HtmlToken[] {
  const result: HtmlToken[] = [];
  let index = 0;
  while (index < source.length) {
    const start = source.indexOf('<', index);
    if (start < 0) { break; }
    if (source.startsWith('<!--', start)) {
      const close = source.indexOf('-->', start + 4);
      const end = close < 0 ? source.length : close + 3;
      result.push({ start: start, end: end, tagEnd: end, closeStart: end, name: '', closing: false, kind: 'comment' });
      index = end; continue;
    }
    const closing = source[start + 1] === '/';
    const namedStart = start + (closing ? 2 : 1);
    if (!letter(source.charCodeAt(namedStart))) { index = start + 1; continue; }
    const namedEnd = nameEnd(source, namedStart);
    const end = tagEnd(source, namedEnd);
    if (end < 0) { break; }
    const name = source.slice(namedStart, namedEnd).toLowerCase();
    const token: HtmlToken = { start: start, end: end, tagEnd: end, closeStart: end,
      name: name, closing: closing, kind: 'tag' };
    if (!closing && /^(?:script|style|textarea|title|xmp|iframe|noembed|noframes|plaintext)$/.test(name)) {
      token.kind = 'raw'; token.end = source.length; token.closeStart = source.length;
      if (name !== 'plaintext') {
        let position = end;
        while (position < source.length) {
          const close = source.indexOf('</', position);
          if (close < 0) { break; }
          const closeNameEnd = nameEnd(source, close + 2);
          if (source.slice(close + 2, closeNameEnd).toLowerCase() !== name) { position = closeNameEnd; continue; }
          const closeEnd = tagEnd(source, closeNameEnd);
          if (closeEnd < 0) { break; }
          token.closeStart = close; token.end = closeEnd; break;
        }
      }
    }
    result.push(token); index = token.end;
  }
  return result;
}

export function replaceMailHtmlTokens(source: string, replace: (token: HtmlToken, tag: string) => string): string {
  const output: string[] = [];
  let offset = 0;
  for (const token of mailHtmlTokens(source)) {
    output.push(source.slice(offset, token.start), replace(token, source.slice(token.start, token.end)));
    offset = token.end;
  }
  output.push(source.slice(offset));
  return output.join('');
}
