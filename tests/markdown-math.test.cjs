const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('../.tools/test/node_modules/typescript');
const modules = new Map();
function load(file) {
  file = path.resolve(file);
  if (file.endsWith('/vendor/engine')) return require(file + '.js');
  file += '.ts';
  if (modules.has(file)) return modules.get(file);
  const out = { exports: {} };
  modules.set(file, out.exports);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  new Function('require', 'exports', 'module', code)(name => load(path.resolve(path.dirname(file), name)), out.exports, out);
  return out.exports;
}
const math = load('harmony/entry/src/main/ets/mail/math/MarkdownMath');
const engine = require('../harmony/entry/src/main/ets/mail/math/vendor/engine.js');
test('Complete inline expression includes all operands and no external font references', () => {
  const svg = engine.equation('a+b', false);
  assert.match(svg, /data-latex="b"/); assert.match(svg, /data-latex="\+"/);
  const fraction = engine.equation('\\frac{a}{b}+x^2', false);
  assert.match(fraction, /mfrac/); assert.match(fraction, /msup/);
  assert.doesNotMatch(svg, /href=|<script|<image|<foreignObject/);
});
test('Markdown math supports inline/block TeX while code, escaped dollars and currency stay literal', () => {
  const source = '# Test\n\n$x^2$\n\n$$\\frac{1}{2}$$\n\n\\(a+b\\) and \\[c+d\\]\n`$code$`\n~~~\n$fenced$\n~~~\n\\$literal\nCosts $5 and $10.';
  const plan = math.markdownMathPlan(source);
  assert.equal(plan.images.length, 4);
  const html = math.renderMathPlan(plan);
  assert.match(html, /<h1>Test/); assert.match(html, /\$code\$/); assert.match(html, /\$fenced\$/);
  assert.match(html, /Costs \$5 and \$10/); assert.equal((html.match(/<svg /g) || []).length, 4);
  assert.doesNotMatch(html, /DMAILMATH/);
  const indented = math.markdownMathPlan('    $code$'); assert.equal(indented.images.length, 0); assert.match(indented.html, /\$code\$/);
});
test('Untrusted Markdown HTML and unsafe links cannot become executable output', () => {
  const plan = math.markdownMathPlan('<img src=x onerror=alert(1)> [bad](javascript:alert) ![picture](https://example.invalid/pixel) [safe](https://example.invalid/)');
  const html = math.renderMathPlan(plan);
  assert.doesNotMatch(html, /<img|href="javascript:|src="https:/);
  assert.match(html, /&lt;img/); assert.match(html, /href="https:\/\/example.invalid\//);
});
test('Equations in Markdown link attributes cannot inject SVG into attributes', () => {
  const html = math.renderMathPlan(math.markdownMathPlan('[link](https://example.invalid/$x$) $y$'));
  assert.equal((html.match(/<svg /g) || []).length, 1);
  assert.match(html, /href="https:\/\/example.invalid\/\$x\$"/);
});
test('HTML preserves attributes, styles, scripts, code and inline pictures; only visible text changes', () => {
  const input = '<style>.x{content:"$x$"}</style><script>"$y$"</script><p title="$z$">$a &lt; b$<img src="cid:pic"></p><pre>$code$</pre><svg><text>$x$</text></svg>';
  const html = math.renderHtmlMath(input);
  assert.match(html, /title="\$z\$"/); assert.match(html, /content:"\$x\$"/); assert.match(html, /<script>"\$y\$"<\/script>/);
  assert.match(html, /<pre>\$code\$<\/pre>/); assert.match(html, /<img src="cid:pic">/);
  assert.match(html, /aria-label="a &lt; b"/); assert.match(html, /<text>\$x\$<\/text>/);
  assert.equal(math.renderHtmlMath(html), html);
});
test('Malformed input, size limits and macro isolation preserve source or fail before sending', () => {
  assert.throws(() => math.markdownMathPlan('a'.repeat(262145)));
  assert.match(math.renderMathPlan(math.markdownMathPlan('$\\unsupportedcmd{x}$')), /unsupportedcmd/);
  assert.throws(() => engine.equation('\\def\\localmacro{a}\\localmacro', false));
  assert.throws(() => engine.equation('\\localmacro', false));
  const start = performance.now();
  assert.equal(math.markdownMathPlan('\\('.repeat(60000)).images.length, 0);
  assert.equal(math.markdownMathPlan('\\'.repeat(100000)).images.length, 0);
  assert.ok(performance.now() - start < 2000);
});

test('Long notes render every equation beyond the former count cap in both mail formats and renderers', () => {
  const equations = Array.from({ length: 96 }, (_, i) => `$x_{${i}}^2$`);
  for (const renderer of ['mathml', 'commonhtml']) {
    const plan = math.markdownMathPlan('# Notes\n\n' + equations.join('\n\n'), '', '', renderer);
    assert.equal(plan.images.length, equations.length);
    const markdown = math.renderMathPlan(plan);
    const html = math.renderHtmlMath(equations.map(s => `<p>${s}</p>`).join(''), renderer);
    for (const result of [markdown, html]) {
      assert.equal((result.match(/role="math"/g) || []).length, equations.length);
      assert.match(result, /aria-label="x_\{95\}\^2"/);
      assert.doesNotMatch(result, /DMAILMATH/);
    }
  }
});

test('Selectable equation source preserves original delimiters and decodes HTML text exactly once', () => {
  const source = String.raw`Inline $x^2$ and \(a+b\).

$$\sum_{i=1}^{n} x_i$$

\[c < d\]`;
  for (const renderer of ['mathml', 'commonhtml']) {
    const plan = math.markdownMathPlan(source, '', '', renderer);
    assert.deepEqual(plan.images.map(item => item.copySource), [String.raw`$x^2$`, String.raw`\(a+b\)`, String.raw`$$\sum_{i=1}^{n} x_i$$`, String.raw`\[c < d\]`]);
    const html = math.renderMathPlan(plan);
    assert.equal((html.match(/data-dmail-math-copy="source"/g) || []).length, 4);
    assert.match(html, /user-select:none/);
    assert.match(html, /user-select:all/);
    assert.doesNotMatch(html, /<script|oncopy=|onclick=/);
    assert.equal(math.renderHtmlMath(html, renderer), html);
    const authored = math.renderHtmlMath(String.raw`<p>Compare $x &lt; y$ and $\text{&amp;lt;}$.</p>`, renderer);
    assert.match(authored, /data-dmail-math-source="\$x &lt; y\$"/);
    assert.match(authored, /data-dmail-math-source="\$\\text\{&amp;lt;\}\$"/);
    assert.equal(math.renderHtmlMath(authored, renderer), authored);
  }
});

test('CommonHTML and MathML render inline and display equations without equation images', () => {
  for (const renderer of ['commonhtml', 'mathml']) {
    const plan = math.markdownMathPlan('Inline $a+b$.\n\n$$\\frac{1}{2}$$\n\n`$literal$`', '', '', renderer);
    const html = math.renderMathPlan(plan);
    assert.equal(plan.images.length, 2);
    assert.match(html, renderer === 'commonhtml' ? /<mjx-container/ : /<math /);
    assert.doesNotMatch(html, /<img|<svg|data:image|cid:/);
    assert.match(html, /\$literal\$/);
    assert.match(html, /style="[^"\n]*display:inline;"/);
    if (renderer === 'commonhtml') {
      assert.match(html, /data:font\/woff2;base64,/);
      assert.doesNotMatch(html, /url\(["']?(?:https?:|dmail-math-font)/);
      assert.equal((html.match(/<style>/g) || []).length, 1);
    } else { assert.match(html, /DMail MathJax TeX/); assert.match(html, /data:font\/woff2;base64,/); }
  }
});

test('Received HTML $$ equations render in both modes without changing author markup or code', () => {
  const source = '<p>Inline $x^2$.</p><p>$$\\frac{1}{2}$$</p><pre>$$untouched$$</pre><img src="cid:original">';
  for (const renderer of ['commonhtml', 'mathml']) {
    const html = math.renderHtmlMath(source, renderer);
    assert.match(html, renderer === 'commonhtml' ? /<mjx-container/ : /<math /);
    assert.match(html, /<pre>\$\$untouched\$\$<\/pre>/);
    assert.match(html, /<img src="cid:original">/);
    assert.equal(math.renderHtmlMath(html, renderer), html);
  }
});

test('Both generated math modes permit embedded fonts; original mail and external resources stay blocked', () => {
  const { preparedMailDocument } = load('harmony/entry/src/main/ets/mail/html/HtmlDocument');
  const original = preparedMailDocument('<p>Example</p>', false);
  assert.doesNotMatch(original, /font-src/);
  assert.equal(math.mathFontDocument(original, 'svg'), original);
  assert.match(math.mathFontDocument(original, 'mathml'), /font-src data:;/);
  const chtml = math.mathFontDocument(original, 'commonhtml');
  assert.match(chtml, /font-src data:;/);
  assert.match(chtml, /default-src 'none'; script-src 'none';/);
  assert.match(chtml, /img-src data:; base-uri 'none'/);
});

test('A legacy formatted draft submits its original source without generated HTML or equation images', async () => {
  const module = { exports: {} }; const requests = [];
  const code = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/NativeSmtpClient.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', code)(name => {
    if (name === 'libthunderbird.so') return { smtpAccountRequest: async value => {
      requests.push(JSON.parse(value)); return JSON.stringify({ accepted: false });
    } };
    if (name === './OutgoingAttachments') return { outgoingAttachmentInput: () => [] };
    throw Error(name);
  }, module, module.exports);
  const draft = Object.assign(new module.exports.OutgoingDraft(), {
    text: '**Original** $x^2$\n\n$$a+b$$', sendFormat: 'formatted'
  });
  await module.exports.submitMail(new module.exports.SmtpSettings(), 'synthetic@example.invalid', draft, true);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].text, draft.text);
  assert.equal(requests[0].forwardHtml, '');
  assert.equal('formatted' in requests[0], false);
  assert.deepEqual(requests[0].attachments, []);
});

test('MathML embeds original Fira Math for all equation glyphs with a local TeX fallback', () => {
  engine.typesetEquation('a+b', false, 'commonhtml');
  const c = engine.mathStyles('commonhtml'), d = engine.mathStyles('mathml');
  const bytes = fs.readFileSync('.tools/math-render/node_modules/@mathjax/mathjax-tex-font/chtml/woff2/mjx-tex-n.woff2');
  const url = 'data:font/woff2;base64,' + bytes.toString('base64');
  assert.ok(c.includes(url));
  const adapted = 'data:font/woff2;base64,' + fs.readFileSync('.tools/math-render/mathml-font/dmail-tex-mathml.woff2').toString('base64');
  assert.ok(d.includes(adapted));
  assert.ok(adapted.length <= 256 * 1024);
  const provenance = JSON.parse(fs.readFileSync('port/markdown-math/bundle-sources.json'));
  const fira = 'data:font/otf;base64,' + fs.readFileSync(provenance.mathmlPrimaryFont.file).toString('base64');
  assert.ok(d.includes(fira));
  assert.ok(d.length < 512 * 1024);
  assert.doesNotMatch(c, /DMail Fira Math|data:font\/otf/);
  assert.equal(provenance.mathmlPrimaryFont.license, 'OFL-1.1');
  assert.equal(provenance.mathmlPrimaryFont.modified, false);
  const font = provenance.mathmlFont;
  assert.equal(font.originalGlyphsAndAdvancesUnchanged, true);
  assert.equal(font.displayGlyphsMatchCommonHTML, true);
  assert.ok(url.length <= 256 * 1024);
  assert.match(d, /math\.dmail-native-math\{font-family:"DMail Fira Math","DMail MathJax TeX",math;font-size:1em;/);
  assert.match(d, /:is\(mi,mn,mo,mtext,ms\)\{font-family:inherit;/);
  assert.doesNotMatch(d, /mjx-container|mjx-c|https?:/);
  assert.match(engine.typesetEquation('a+b', false, 'mathml'), /<math class="dmail-native-math"/);
});

test('Greek Sigma remains a letter and sum remains a distinct summation operator', () => {
  const d = engine.typesetEquation('\\Sigma \\qquad \\sum_{i=1}^n i', true, 'mathml');
  assert.match(d, /<mi[^>]*>&#x3A3;<\/mi>/);
  assert.match(d, /<mo[^>]*>&#x2211;<\/mo>/);
  assert.match(d, /<mo[^>]*class="dmail-native-operator"[^>]*>&#x2211;/);
  assert.doesNotMatch(d, /<mi[^>]*class="dmail-native-operator"/);
  assert.match(d, /<munderover/);
  const c = engine.typesetEquation('\\Sigma \\quad \\sum', false, 'commonhtml');
  assert.match(c, /mjx-c3A3/); assert.match(c, /mjx-c2211/);
});

test('Native operator layout respects inline/display, limits overrides and nested styles', () => {
  const inline = engine.typesetEquation('\\sum_{i=1}^n i', false, 'mathml');
  assert.doesNotMatch(inline, /display="block"|displaystyle="true"/);
  assert.match(inline, /<munderover/);
  const display = engine.typesetEquation('\\sum_{i=1}^n i', true, 'mathml');
  assert.match(display, /display="block"/);
  assert.match(display, /<munderover/);
  const limits = engine.typesetEquation('\\sum\\limits_{i=1}^n i', false, 'mathml');
  assert.match(limits, /<munderover/);
  assert.match(limits, /movablelimits="false"/);
  const side = engine.typesetEquation('\\sum\\nolimits_{i=1}^n i', true, 'mathml');
  assert.match(side, /<msubsup/);
  assert.doesNotMatch(side, /<munderover/);
  const nested = engine.typesetEquation('\\frac{\\displaystyle\\sum_i x_i}{\\textstyle\\sum_j y_j}', true, 'mathml');
  assert.match(nested, /displaystyle="true"/);
  // A fraction already supplies compact style; the serializer may omit false.
  const override = engine.typesetEquation('\\displaystyle\\sum_i x_i+\\textstyle\\sum_j y_j', true, 'mathml');
  assert.match(override, /displaystyle="false"/);
});
