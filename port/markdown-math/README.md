# Offline Markdown and math

App-owned `engine.js` bundles Marked 18.0.13 (MIT) and MathJax 4.1.3 with
MathJax TeX font data and WOFF2 fonts (Apache-2.0). Sources:
https://github.com/markedjs/marked and https://github.com/mathjax/MathJax-src,
https://github.com/mathjax/MathJax-fonts. Original license texts accompany this
folder and the app. Pinned upstream module files are unchanged. The app-owned runtime adapter
is described below. `bundle-sources.json` records every input SHA-256 and
output SHA-256; `package-lock.json` records npm tarball integrity.

## Component licenses

Marked remains MIT licensed, with its original copyright and full permission
notice preserved in `licenses/marked.txt`, the repository's `licenses/marked.txt`
and app raw resources. MathJax and its TeX font data retain Apache-2.0.
The project-level MPL-2.0 license does not replace these upstream terms.
Keep adaptations of MIT renderer source under MIT and identify local changes.

The HarmonyOS alternative `@cangjie-tpc/formula_hybrid` 1.3.2 is still under
evaluation. Its complete archive license is preserved in
`licenses/formula_hybrid-1.3.2.txt`: it includes the MIT notice for Nano Michael's
formula code and an Apache-2.0 text. This is not a claim that its bundled
runtimes and fonts are all MIT licensed or that it is already shipped in D-Mail.

## Rebuilding

Reproduce from the repository root (Node 22, Python with fonttools 4.60.1
and brotlicffi 1.0.9.2; build tools are not shipped):

```
mkdir -p .tools/math-render
cp port/markdown-math/package{,-lock}.json .tools/math-render/
npm ci --prefix .tools/math-render --ignore-scripts --no-audit --no-fund
python3 port/markdown-math/build-mathml-font.py
node port/markdown-math/build.cjs
```

The bundler aliases MathJax's `#default-font` to the pinned TeX font, avoiding an
unused second font. Input permits only the base and AMS packages; no autoload,
HTML/URL extension, user configuration or remote renderer. Each equation has
an isolated TeX parser. `fontCache: none` emits paths without external references;
inline line splitting is disabled so a single SVG contains the whole expression.

The app-owned `LocalTexFont` adapter defines numeric glyph and delimiter entries
explicitly instead of using `Object.assign` on prototype-linked font tables.
On the tested Ark runtime, the upstream copy path mixed glyphs between variants.
The same copy implementation is applied only to MathJax's shared FontData base
class. CommonHTML's original override still annotates font families and combining
marks afterward; skipping that step caused clipping. No global Object patch is
used and original upstream font tables are preserved.

Production offers CommonHTML and MathML. CommonHTML CSS references bundled WOFF2
data URLs; MathML serializes the compiled TeX tree for native browser layout.
D uses unmodified Fira Math 0.3.4 for the entire equation, including letters,
numbers and operators. Its original OpenType MATH table controls layout, with
no manual scaling or replacement of its metrics. The committed source font is
`fonts/FiraMath-Regular.otf`, SHA-256
`2028cbd3dd4d8c0cf1608520eb4759956a83a67931d7b6d8e7c313520186e35b`,
from https://mirrors.ctan.org/fonts/firamath.zip. The bundler verifies this pin
and embeds the original OTF bytes. Its **OFL-1.1** license/copyright is retained
in `licenses/FiraMath-OFL-1.1.txt`, the repository licenses and app raw resources.
Fira covers sums, products and integrals but omits several big set operators.
The previously corrected MathJax TeX font remains the next local fallback,
followed by the browser's math family for any remaining missing glyphs.
All families are scoped to generated D equations; authored email fonts and C
are unchanged. The following describes the TeX fallback, not Fira's metrics.
`build-mathml-font.py` creates a D-only copy of
`mjx-tex-n.woff2`, retains the rule-thickness correction (0 to 60 font units),
adds an OpenType MATH table and imports 16 display-operator glyphs from
`mjx-tex-lo.woff2`. The 1.3em minimum selects the 1.4em display sum (or the
larger integral), while inline MathML retains the original glyph. Axis 0.25em,
upper gap/rise 0.111/0.2em and lower gap/drop 0.167/0.6em reproduce C's TeX
operator constants. Side-script shifts and base drops use C's TeX metrics too,
including its script-scale factor for drops; zero drops had placed inline-sum
superscripts too high. Other constants retain the earlier MathML fallback values,
rounded to font units; the script-script percentage rounds 50.41% to 50%.
Display integral advances include C's 0.388em italic correction, which C adds
in JavaScript but OpenType expects inside the advance before placing scripts.
The builder verifies original glyph outlines, advances and Unicode mappings,
and all imported display shapes against the pinned fonts. Glyph counts, CFF,
horizontal-metric counts, checksum and Unicode-index metadata are regenerated.
C's original font bytes, markup and CSS remain unchanged. The derived font
retains Apache-2.0 and records both upstream font hashes.

MathML Core uses `post.underlineThickness` when a font has no OpenType MATH table;
zero made fraction/radical rules invisible on HarmonyOS. See
https://www.w3.org/TR/mathml-core/#layout-constants-mathconstants.
The browser still controls D's layout; matched operator metrics do not claim
identical line/paragraph spacing or layout for every expression. Existing
non-operator glyph shapes remain unchanged. No general delimiter assembly or
complete OpenType conversion of every MathJax font is included.
SVG remains only for comparison/legacy renderer tests. Twenty-two native C/D
markup results are compared with checked-in host references, and screenshots
validate actual font layout rather than relying on markup equality alone.

`MarkdownMath.ts` handles bounded delimiters and prepared HTML text spans.
Markdown author HTML is escaped, image syntax becomes alt text, and links accept
only HTTP(S) and mailto. Existing received HTML keeps its original markup and
picture plan. The email WebView still disables JavaScript and network access.
The trusted typesetter runs in app code, never inside an email document.

`MarkdownPreview.ets` generates local preview HTML. The composer and stored drafts
retain their original source; there is no Markdown-to-HTML sending path.
Received rendering uses `math7:mathml:` and `math3:commonhtml:` for new attempts
after removing the equation-count cap. Successful documents at the preceding
`math6:mathml:` and `math2:commonhtml:` keys remain reusable; old failures can
retry locally once. Input, per-expression and output-size limits remain.
