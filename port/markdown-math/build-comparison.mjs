// Review artifact only. Does not change the mail renderer or a device package.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const modules = path.join(root, '.tools/math-render/node_modules');
const load = name => import(pathToFileURL(path.join(modules, name)).href);
const { mathjax } = await load('@mathjax/src/mjs/mathjax.js');
const { TeX } = await load('@mathjax/src/mjs/input/tex.js');
const { CHTML } = await load('@mathjax/src/mjs/output/chtml.js');
const { MathJaxTexFont } = await load('@mathjax/mathjax-tex-font/mjs/chtml.js');
const { liteAdaptor } = await load('@mathjax/src/mjs/adaptors/liteAdaptor.js');
const { RegisterHTMLHandler } = await load('@mathjax/src/mjs/handlers/html.js');
const { SerializedMmlVisitor } = await load('@mathjax/src/mjs/core/MmlTree/SerializedMmlVisitor.js');
const { STATE } = await load('@mathjax/src/mjs/core/MathItem.js');
await load('@mathjax/src/mjs/input/tex/base/BaseConfiguration.js');
await load('@mathjax/src/mjs/input/tex/ams/AmsConfiguration.js');
const adaptor = liteAdaptor(); RegisterHTMLHandler(adaptor);
const output = new CHTML({ fontData: MathJaxTexFont, fontURL: 'FONTS', adaptiveCSS: true });
const document = mathjax.document('', { InputJax: new TeX({ packages: ['base', 'ams'] }), OutputJax: output });
const equations = ['a+b', String.raw`\frac{a}{b}+x^2`, String.raw`\sum_{i=1}^{n} i = \frac{n(n+1)}{2}`];
const common = equations.map((tex, i) => adaptor.outerHTML(document.convert(tex, { display: i === 2, em: 16, ex: 8, containerWidth: 480 })));
const visitor = new SerializedMmlVisitor();
const appMath = await import(pathToFileURL(path.join(root, 'harmony/entry/src/main/ets/mail/math/vendor/engine.js')).href);
const nativeMath = equations.map((tex, i) => appMath.typesetEquation(tex, i === 2, 'mathml'));
let fontStyles = adaptor.textContent(output.styleSheet(document));
fontStyles = fontStyles.replace(/url\(["']?[^)"']*\/(mjx-[^)"']+\.woff2)["']?\)/g, (_, filename) => {
  const bytes = fs.readFileSync(path.join(modules, '@mathjax/mathjax-tex-font/chtml/woff2', filename));
  return `url("data:font/woff2;base64,${bytes.toString('base64')}")`;
});
fontStyles += appMath.mathStyles('mathml');
if (/url\((?!"data:)/.test(fontStyles)) throw Error('Comparison must use embedded fonts only');
const evidence = path.join(root, '.tools/math-render/emulator');
const svgs = equations.map((_, i) => fs.readFileSync(path.join(evidence, `equation-${i}.svg`), 'utf8'));
const pngs = equations.map((_, i) => 'data:image/png;base64,' + fs.readFileSync(path.join(evidence, `equation-${i}.png`)).toString('base64'));
const metrics = svgs.map(svg => ({
  width: Number(/width="([\d.]+)ex"/.exec(svg)[1]),
  height: Number(/height="([\d.]+)ex"/.exec(svg)[1]),
  baseline: Number(/vertical-align: ([\d.-]+)ex/.exec(svg)[1])
}));
const image = (i, baseline) => {
  const m = metrics[i];
  if (!baseline) return `<span style="${i === 2 ? 'display:block;text-align:center;margin:12px 0' : 'display:inline-block;vertical-align:middle'}"><img src="${pngs[i]}" width="${Math.ceil(m.width * 8)}" height="${Math.ceil(m.height * 8)}" style="max-width:100%;height:auto;background:#fff;vertical-align:middle"></span>`;
  return `<img src="${pngs[i]}" style="width:${m.width}ex;height:${m.height}ex;vertical-align:${m.baseline}ex;background:#fff">`;
};
const modes = [
  { title: 'A · Current PNG', tag: 'Installed behavior', body: 'Fixed pixel size and middle alignment. The baseline information is lost.', render: i => image(i, false) },
  { title: 'B · SVG inside HTML', tag: 'Vector outlines · Wikipedia-style output', body: 'Keeps MathJax’s baseline and scales sharply. No math-font download is needed.', render: i => svgs[i] },
  { title: 'C · CommonHTML', tag: 'HTML + CSS + fonts', body: 'MathJax builds the formula from HTML elements and bundled math fonts. No equation image.', render: i => common[i] },
  { title: 'D · Native MathML', tag: 'Browser math layout', body: 'The browser typesets structured mathematics directly, using C’s MathJax TeX letter shapes.', render: i => nativeMath[i] }
];
const rows = modes.map(mode => `<section><header><small>${mode.tag}</small><h2>${mode.title}</h2><p>${mode.body}</p></header><div class="sample"><p class="line"><span class="guide"></span>The value ${mode.render(0)} is known.</p><p class="line"><span class="guide"></span>Then ${mode.render(1)} is positive.</p><div class="display">${mode.render(2)}</div><p class="foot">Body text stays editable Markdown.</p></div></section>`).join('');
const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>D-Mail equation rendering comparison</title><style>${fontStyles}
*{box-sizing:border-box}body{margin:0;padding:32px;background:#eef1f4;color:#17212d;font-family:Arial,sans-serif}main{max-width:1280px;margin:auto}h1{font-size:28px;margin:0 0 10px}.intro{max-width:850px;line-height:1.55;margin:0 0 20px}label{display:inline-block;padding:9px 12px;cursor:pointer;margin-bottom:18px}input{margin-left:12px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px;--text:20px}section{border:1px solid #d8dee5;border-radius:12px;overflow:hidden;background:white}header{padding:18px 22px;background:#f7f9fb;color:#17212d;min-height:138px}small{text-transform:uppercase;letter-spacing:.06em;font-size:11px;color:#53677a}h2{font-size:20px;margin:8px 0}header p{font-size:14px;line-height:1.5;margin:0}.sample{font-size:var(--text);line-height:1.55;padding:14px 22px 4px;color:#141b23;overflow:hidden}.sample p{margin:18px 0}.sample img,.sample svg{max-width:100%}.display{text-align:center;min-height:100px;display:flex;align-items:center;justify-content:center;margin:18px 0}.foot{font-size:14px;color:#687685}.guide{display:none;position:relative;width:0;height:0;vertical-align:baseline}.guide:before{content:'';position:absolute;left:-10px;top:0;width:900px;border-top:1px dashed #ce528888;pointer-events:none}#guides:checked~.grid .guide{display:inline-block}#size16:checked~.grid{--text:16px}#size24:checked~.grid{--text:24px}#dark:checked~.grid section{background:#20232a}#dark:checked~.grid .sample{color:#eef1f6}#dark:checked~.grid .foot{color:#aeb9c8}.notes{font-size:14px;line-height:1.6;color:#425268;margin-top:22px}a{color:#2267b1}@media(max-width:720px){body{padding:18px}.grid{grid-template-columns:1fr}header{min-height:0}label{padding:8px 4px}}
</style></head><body><main><h1>Equation rendering comparison</h1><p class="intro">Identical equations, four ways of placing them in HTML. A uses the actual PNGs produced by HarmonyOS. B uses the verified SVG output. C is MathJax CommonHTML with embedded fonts. D uses native MathML with the same MathJax TeX letter shapes. All conversion was performed locally. This is a browser comparison, not a new phone build.</p><input id="size16" type="radio" name="size"><label for="size16">16 px</label><input id="size20" type="radio" name="size" checked><label for="size20">20 px</label><input id="size24" type="radio" name="size"><label for="size24">24 px</label><input id="guides" type="checkbox" checked><label for="guides">Text baseline guides</label><input id="dark" type="checkbox"><label for="dark">Dark background</label><div class="grid">${rows}</div><div class="notes"><p><b>What to compare:</b> the bottom of ordinary letters against the pink baseline, the size of inline math next to prose, sharpness when zooming, and white PNG backgrounds in dark mode.</p><p><b>App versus outgoing mail:</b> we control D-Mail’s HTML viewer. Recipient clients control their own HTML, CSS and font support. C and D load bundled fonts locally. D uses a separate font copy with a nonzero rule-thickness value for native MathML; C is unchanged.</p><p>Renderer and font outlines: MathJax / MathJax TeX, Apache-2.0. Markdown parser: Marked, MIT. Original notices remain separate from D-Mail’s MPL code. <a href="https://docs.mathjax.org/en/latest/output/html.html">CommonHTML documentation</a> · <a href="https://docs.mathjax.org/en/latest/output/svg.html">SVG documentation</a></p></div></main></body></html>`;
const out = path.join(root, '.tools/math-render/comparison'); fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'index.html'), html);
fs.writeFileSync(path.join(out, 'metrics.json'), JSON.stringify(metrics, null, 2));
console.log(path.join(out, 'index.html'));
