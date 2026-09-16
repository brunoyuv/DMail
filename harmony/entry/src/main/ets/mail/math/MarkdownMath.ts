// MPL-2.0: https://mozilla.org/MPL/2.0/
import { typesetEquation, mathStyles, markdown } from './vendor/engine';
import { mailHtmlTokens } from '../html/HtmlTokens';
import { HTML_ATTRIBUTE_ENTITIES } from '../html/HtmlEntities';
import { prepareMailHtml } from '../html/HtmlDocument';
export interface MathImage { source: string; original: string; svg: string; display: boolean; marker: string; }
export interface MathPlan { html: string; images: MathImage[]; renderer: string; styles: string; }
export const MATH_RENDER_REVISION = 'math2';
const MAX_INPUT = 262144, MAX_OUTPUT = 4 * 1024 * 1024;
function escape(value: string): string { return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function decodeMailHtmlEntities(value: string): string {
  return value.replace(/&(#x[0-9a-f]{1,6}|#[0-9]{1,7}|[a-z][a-z0-9]{1,31});/gi, (match: string, entity: string): string => {
    if (entity[0] !== '#') { return HTML_ATTRIBUTE_ENTITIES.get(entity) ?? match; }
    const point = entity[1].toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
    return point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff) ? String.fromCodePoint(point) : match;
  });
}
function escaped(source: string, at: number): boolean {
  let slashes = 0; for (let i = at - 1; i >= 0 && source[i] === '\\'; i--) { slashes++; } return slashes % 2 === 1;
}
// Delimiters are scanned once, with a bounded expression window. Code stays literal.
function replaceMath(source: string, render: (tex: string, display: boolean, original: string) => string, code: boolean): string {
  const parts: string[] = [], closes = new Map<string, number>(); let last = 0, at = 0;
  while (at < source.length) {
    if (code && (source[at] === '`' || source.startsWith('~~~', at)) && !escaped(source, at)) {
      let end = at + 1; while (source[end] === source[at]) { end++; }
      const close = source.indexOf(source.slice(at, end), end);
      at = close < 0 ? source.length : close + end - at; continue;
    }
    const open = source.startsWith('$$', at) ? '$$' : source.startsWith('\\[', at) ? '\\[' : source.startsWith('\\(', at) ? '\\(' : source[at] === '$' ? '$' : '';
    if (!open || escaped(source, at)) { at++; continue; }
    const begin = at + open.length, closeToken = open === '\\[' ? '\\]' : open === '\\(' ? '\\)' : open;
    if (open === '$' && /\s/.test(source[begin] || ' ')) { at++; continue; }
    let end = closes.get(closeToken);
    if (end === undefined || (end >= 0 && end < begin)) {
      end = source.indexOf(closeToken, begin);
      while (end >= 0 && escaped(source, end)) { end = source.indexOf(closeToken, end + closeToken.length); }
      closes.set(closeToken, end);
    }
    if (end < 0 || end - begin > 4096) { at = begin; continue; }
    if (open === '$' && (/\s/.test(source[end - 1] || ' ') || /[0-9]/.test(source[end + 1] || '') || source.slice(begin, end).includes('\n'))) { at = begin; continue; }
    const finish = end + closeToken.length;
    parts.push(source.slice(last, at), render(source.slice(begin, end), open === '$$' || open === '\\[', source.slice(at, finish)));
    last = finish; at = finish;
  }
  parts.push(source.slice(last)); return parts.join('');
}
function prefix(source: string): string {
  const used = new Set<string>();
  for (const match of source.matchAll(/DMAILMATH([0-9]+)TOKEN/g)) { used.add(match[1]); }
  let serial = 0; while (used.has(String(serial))) { serial++; }
  return 'DMAILMATH' + serial + 'TOKEN';
}
function appendMath(images: MathImage[], token: string, tex: string, display: boolean, original: string, renderer: string): string {
  let svg: string;
  try { svg = typesetEquation(tex, display, renderer); } catch (_) { return original; }
  const marker = token + images.length + 'END';
  images.push({ source: tex, original, svg, display, marker }); return marker;
}
export function markdownMathPlan(source: string, show = '', hide = '', renderer = 'svg'): MathPlan {
  if (source.length > MAX_INPUT) { throw new Error('Markdown input limit'); }
  const images: MathImage[] = [], token = prefix(source);
  const protectedText = replaceMath(source, (tex, display, original) => appendMath(images, token, tex, display, original, renderer), true);
  let html = prepareMailHtml(markdown(protectedText), show, hide);
  const visible = new Set<string>(); let last = 0, depth = 0;
  for (const tag of mailHtmlTokens(html)) {
    if (depth === 0) { for (const item of images) { if (html.slice(last, tag.start).includes(item.marker)) { visible.add(item.marker); } } }
    if (['code', 'pre'].includes(tag.name)) { depth = Math.max(0, depth + (tag.closing ? -1 : 1)); }
    last = tag.end;
  }
  if (depth === 0) { for (const item of images) { if (html.slice(last).includes(item.marker)) { visible.add(item.marker); } } }
  for (let i = images.length - 1; i >= 0; i--) {
    if (!visible.has(images[i].marker)) { html = html.split(images[i].marker).join(escape(images[i].original)); images.splice(i, 1); }
  }
  if (html.length + images.reduce((n, image) => n + image.svg.length, 0) > MAX_OUTPUT) { throw new Error('Math output limit'); }
  return { html, images, renderer, styles: images.length ? mathStyles(renderer) : '' };
}
export function replaceMathImages(plan: MathPlan, render: (item: MathImage) => string): string {
  const parts: string[] = []; let last = 0;
  const replace = (text: string, visible: boolean): string => {
    for (const item of plan.images) {
      text = text.split(item.marker).join(visible ? render(item) : escape(item.original));
    }
    return text;
  };
  for (const tag of mailHtmlTokens(plan.html)) {
    parts.push(replace(plan.html.slice(last, tag.start), true), replace(plan.html.slice(tag.start, tag.end), false)); last = tag.end;
  }
  parts.push(replace(plan.html.slice(last), true)); return parts.join('');
}
export function mathFontDocument(html: string, renderer: string): string {
  // Only generated math documents may load embedded, bundled fonts. Mail
  // scripts, external fonts, network, frames and objects remain blocked.
  return ['commonhtml', 'mathml'].includes(renderer) ? html.replace("style-src 'unsafe-inline'; img-src", "style-src 'unsafe-inline'; font-src data:; img-src") : html;
}
export function renderMathPlan(plan: MathPlan): string {
  const html = replaceMathImages(plan, item => `<span role="math" aria-label="${escape(item.source)}" title="${escape(item.source)}" style="${item.display ? 'display:block;text-align:center;overflow-x:auto;margin:0.75em 0;' : 'display:inline;'}">${item.svg}</span>`);
  if (!plan.styles) { return html; }
  const styles = '<style>' + plan.styles + '</style>';
  return html.includes('</head>') ? html.replace('</head>', styles + '</head>') : styles + html;
}
// Operate only on visible text spans; never on attributes, CSS, scripts or code.
export function renderHtmlMath(html: string, renderer = 'svg'): string {
  if (html.length > MAX_OUTPUT || !/[\$\\]/.test(html)) { return html; }
  const parts: string[] = [], images: MathImage[] = []; let last = 0, codeDepth = 0;
  const token = prefix(html);
  for (const tag of mailHtmlTokens(html)) {
    const text = html.slice(last, tag.start);
    parts.push(codeDepth === 0 ? replaceMath(text, (tex, display, original) => {
      const marker = appendMath(images, token, decodeMailHtmlEntities(tex), display, original, renderer); return marker;
    }, false) : text, html.slice(tag.start, tag.end));
    if (['code', 'pre', 'textarea', 'math', 'svg', 'mjx-container'].includes(tag.name)) { codeDepth = Math.max(0, codeDepth + (tag.closing ? -1 : 1)); }
    last = tag.end;
  }
  const tail = html.slice(last);
  parts.push(codeDepth === 0 ? replaceMath(tail, (tex, display, original) => appendMath(images, token, decodeMailHtmlEntities(tex), display, original, renderer), false) : tail);
  const result = renderMathPlan({ html: parts.join(''), images, renderer, styles: images.length ? mathStyles(renderer) : '' });
  return result.length <= MAX_OUTPUT ? result : html;
}
