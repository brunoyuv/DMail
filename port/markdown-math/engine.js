// MPL-2.0. App-owned offline typesetting; never evaluate email HTML or scripts.
import { mathjax } from '@mathjax/src/js/mathjax.js';
import { TeX } from '@mathjax/src/js/input/tex.js';
import { SVG } from '@mathjax/src/js/output/svg.js';
import { CHTML } from '@mathjax/src/js/output/chtml.js';
import { FontData } from '@mathjax/src/js/output/common/FontData.js';
import { MathJaxTexFont as ChtmlTexFont } from '@mathjax/mathjax-tex-font/js/chtml.js';
import { SerializedMmlVisitor } from '@mathjax/src/js/core/MmlTree/SerializedMmlVisitor.js';
import { STATE } from '@mathjax/src/js/core/MathItem.js';
import { fontDataUrls } from './font-data.js';
import { liteAdaptor } from '@mathjax/src/js/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from '@mathjax/src/js/handlers/html.js';
import { MathJaxTexFont } from '@mathjax/mathjax-tex-font/js/svg.js';
import '@mathjax/src/js/input/tex/base/BaseConfiguration.js';
import '@mathjax/src/js/input/tex/ams/AmsConfiguration.js';
import { Marked } from 'marked';
const adaptor = liteAdaptor(); RegisterHTMLHandler(adaptor);
// No autoload, URL/HTML extensions, user configuration, or remote fonts.
class LocalTexFont extends MathJaxTexFont {
  // Ark runtime Object.assign on these prototype-linked numeric tables mixed
  // glyphs between variants. Define own entries explicitly, preserving the
  // upstream variant inheritance and links. No global Object patch is used.
  defineChars(name, chars) {
    const variant = this.variant[name];
    for (const target of [variant.chars, ...variant.linked]) {
      for (const key of Object.keys(chars)) {
        Object.defineProperty(target, key, { value: chars[key], writable: true, enumerable: true, configurable: true });
      }
    }
  }
  defineDelimiters(delimiters) {
    for (const key of Object.keys(delimiters)) {
      Object.defineProperty(this.delimiters, key, { value: delimiters[key], writable: true, enumerable: true, configurable: true });
    }
  }
}
const output = new SVG({ fontData: LocalTexFont, fontCache: 'none', linebreaks: { inline: false } });
// Patch only MathJax's shared table-copy implementation. CHTML's own override
// must still annotate glyph font families and combining marks after the copy.
FontData.prototype.defineChars = LocalTexFont.prototype.defineChars;
FontData.prototype.defineDelimiters = LocalTexFont.prototype.defineDelimiters;
const chtml = new CHTML({ fontData: ChtmlTexFont, fontURL: 'dmail-math-font', adaptiveCSS: true });
const visitor = new SerializedMmlVisitor();
let lastChtmlDocument;
export function typesetEquation(source, display, renderer) {
  if (renderer === 'svg') return equation(source, display);
  if (!['commonhtml', 'mathml'].includes(renderer) || source.length > 4096) throw Error('Math expression limit');
  const tex = new TeX({ packages: ['base', 'ams'], maxBuffer: 4096, maxMacros: 256 });
  const document = mathjax.document('', { InputJax: tex, OutputJax: chtml });
  let value;
  if (renderer === 'mathml') {
    value = visitor.visitTree(document.convert(source, { display, end: STATE.COMPILED })).replace('<math ', '<math class="dmail-native-math" ');
    // Keep operator annotations for fixture inspection. D now uses Fira Math
    // throughout; the corrected TeX font covers glyphs absent from Fira.
    value = value.replace(/(<mo\b[^>]*)(>)(?:&#x(220F|2210|2211|222B|222C|222D|222E|22C0|22C1|22C2|22C3|2A00|2A01|2A02|2A04|2A06);)/g,
      '$1 class="dmail-native-operator"$2&#x$3;');
  } else {
    value = adaptor.outerHTML(document.convert(source, { display, em: 16, ex: 8, containerWidth: 480 }));
    lastChtmlDocument = document;
  }
  if (value.length > 131072 || /(?:data-mjx-error=|<merror|href=|<script|<foreignObject|<image)/i.test(value)) throw Error('Unsupported math');
  return value;
}
export function mathStyles(renderer) {
  if (renderer === 'mathml') {
    // Fira's original glyphs and MATH table provide consistent sans-serif
    // equations. Keep the corrected TeX variants as a local coverage fallback.
    // These private families apply only to generated D equations.
    return '@font-face{font-family:"DMail Fira Math";src:url("' + fontDataUrls['FiraMath-Regular.otf'] + '") format("opentype");}' +
      '@font-face{font-family:"DMail MathJax TeX";src:url("' + fontDataUrls['dmail-tex-mathml.woff2'] + '") format("woff2");}' +
      'math.dmail-native-math{font-family:"DMail Fira Math","DMail MathJax TeX",math;font-size:1em;}' +
      'math.dmail-native-math :is(mi,mn,mo,mtext,ms){font-family:inherit;}';
  }
  if (renderer !== 'commonhtml' || !lastChtmlDocument) return '';
  const css = adaptor.textContent(chtml.styleSheet(lastChtmlDocument));
  return css.replace(/url\(["']?[^)"']*\/(mjx-[^)"']+\.woff2)["']?\)/g, (_, file) => {
    if (!fontDataUrls[file]) throw Error('Missing bundled math font');
    return `url("${fontDataUrls[file]}")`;
  });
}
export function equation(source, display) {
  if (source.length > 4096) throw Error('Math expression limit');
  const tex = new TeX({ packages: ['base', 'ams'], maxBuffer: 4096, maxMacros: 256 });
  const document = mathjax.document('', { InputJax: tex, OutputJax: output });
  const node = document.convert(source, { display, em: 16, ex: 8, containerWidth: 480 });
  const svg = adaptor.firstChild(node);
  if (!svg || adaptor.kind(svg) !== 'svg' || adaptor.childNodes(node).length !== 1) throw Error('Invalid math');
  if (adaptor.outerHTML(node).includes('data-mjx-error=')) throw Error('Unsupported math');
  const value = adaptor.outerHTML(svg);
  if (value.length > 131072 || /(?:href=|<script|<foreignObject|<image)/i.test(value)) throw Error('Math output limit');
  return value;
}
const parser = new Marked({ async: false, gfm: true, breaks: true });
parser.use({ renderer: { link({href, title, tokens}) { const label = this.parser.parseInline(tokens); if (!/^(https?:\/\/|mailto:)/i.test(href) || /[\u0000-\u0020\u007f]/.test(href)) return label; const safe = href.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;'); return `<a href="${safe}">${label}</a>`; }, html({text}) { return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }, image({text}) { return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); } } });
export function markdown(source) {
  if (source.length > 262144) throw Error('Markdown input limit');
  return parser.parse(source);
}
