# Markdown, equations and received timestamps

## Current Pura X installation

Following the user's explicit installation request, the full Fira Math build is
installed in place on Pura X (VDE-AL00), version 1.0.2 / 1000002. App identity
and account-storage identity were verified before and after the update.
Production was not launched. The signed input hash was verified; the OS denied
reading the installed HAP hash directly. MatePad production was not updated.
See [1.0.2 validation and installation](release-1.0.2-validation.json).
The initial Fira package was installed under 1.0.1 before release checks found
and corrected the reader’s WOFF2-only font request allowlist. 1.0.2 accepts
Fira’s bundled OTF too; device font rendering itself has not yet been visually
checked in this release.
The preceding native-text / corrected-TeX build is recorded in
[the previous installation record](mathml-pura-installation.json).

## Current D font choice: Fira Math

The user selected option 2 (Fira Math), then asked to apply it throughout D's
equations to match sans-serif prose. The current source embeds the unmodified
Fira Math 0.3.4 OTF for letters, numbers and operators, with its original MATH
metrics. The corrected TeX font remains a local fallback for missing glyphs,
including several big set operators. C's font bytes, markup and CSS are unchanged.

The font update's `math6:mathml:` cache revision regenerated previous rendered documents
locally on the next open, preserving saved mail and avoiding a refetch. Fira's
OFL-1.1 license is retained separately in repository and app notices. This change
is now installed on Pura X following the user’s explicit request. See [Fira validation](mathml-fira-validation.json).

### Previous native-text choice (superseded on Pura X)

The preceding D build restored the browser's native `math` font for ordinary
text, retaining corrected TeX operators and MATH metrics. Its cache revision was
`math5:mathml:`. Synthetic MatePad previews and the core test passed, with C
pixel-identical. See [native-font validation](mathml-native-font-validation.json).

## Earlier installation hold and MatePad comparison

The user paused the D font update before installation. Pura X retains the
previous source-only / C-and-D build recorded in `markdown-math-cd-validation.json`.
Neither production app was updated or launched in the font comparison.

The isolated MatePad comparison passed: current D renders `\Sigma` and `\sum`
with nearly identical appearance, while the candidate D font makes them visibly
distinct. Both parse as different characters (Greek letter U+03A3 and summation
operator U+2211). The visible C preview was pixel-identical across both runs
(1,066,000 compared pixels). Fractions and radicals remain visible in candidate D.
All three native tests and 22 markup references passed; the isolated app was
removed and process/emulator absence verified. The device lists a math font,
but reading that system font file was denied, so the exact selected fallback
font is not identified. See [validation](mathml-font-matepad-validation.json).

## Earlier TeX operator correction: D versus C

The user's HTML reference is C (CommonHTML). Both modes turn Markdown into
HTML and share the TeX parser; they use different equation layout engines.
C positions operators and limits with MathJax's TeX metrics and generated CSS.
D serializes the parsed tree to MathML and delegates placement to ArkWeb.

The pinned C sum metrics are 0.75em ascent / 0.25em descent for the small
operator and 0.95em / 0.45em for the large display operator. C also supplies
explicit upper/lower limit spacing. The earlier D primary font copy contained
the glyph outlines but no OpenType MATH table or large-operator variants.
Its rule-thickness correction fixed fraction/radical bars, not sum placement.
For example, C's math axis is 0.25em; the font's x-height gives a native fallback
axis of 0.2155em. Missing operator-size and limit-spacing constants use fallback
values under [MathML Core](https://www.w3.org/TR/mathml-core/#layout-constants-mathconstants).
This explains why sharing C's glyphs alone cannot reproduce C's layout.

The earlier corrected TeX font (now D’s fallback) includes native axis/limit metrics and 16 existing C display
operator glyphs. The original inline glyph outlines, widths and Unicode mappings
are preserved. Side-script shifts/drop metrics also keep inline sum limits beside
the operator instead of raising the superscript above it. The synthetic MatePad sum uses the same 50-pixel display glyph
height as C, with visible upper/lower limit gaps. C's preview remains identical
across 1,066,000 compared pixels; 18 host expressions also preserve C markup/CSS
exactly. This corrects operator sizing and placement, without claiming identical
paragraph spacing between renderers. See [operator validation](mathml-operator-validation.json).
The operator comparison used signed isolated test HAPs. A subsequent production
rebuild and authorized Pura X installation are recorded above; earlier font-candidate
HAPs predate these corrections.

## Current behavior

The user selected C (MathJax CommonHTML) and D (native MathML), then removed
outgoing formatted HTML from scope and renewed installation on Pura X.
The plain editor, saved draft source and existing Swift sending path are kept.
Markdown/TeX is sent as the original text; there is no outgoing HTML setting.
Legacy draft format fields and database columns do not enable formatted sending.

Per-account Settings → Markdown and math offers:

- Optional rendering when reading (off by default, applied on the next open).
- MathML (D, the default) or CommonHTML (C, HTML/CSS with bundled fonts).
- Compose → More → Preview message for a local rendered preview of any saved draft.

Use `$...$` for inline math and `$$...$$` on a separate line for display math.
The renderer also accepts `\(...\)` and `\[...\]`. Code spans/fences remain
literal. Unsupported expressions retain their source. There is no equation-count cap. Rendering retains size limits of 4,096
characters per equation, 262,144 input characters, 4 MiB generated output and
1 MiB composer preview output.

Reading preserves downloaded source and the original prepared document.
Rendered documents use separate revision/renderer cache keys. Reopening old
cached messages uses their existing source without downloading again; switching
renderer selects its matching variant. Disabling rendering restores the original.
Optional rendering failure leaves the original body readable.

Both modes use the existing HTML reader. No equation PNGs are generated.
CommonHTML uses embedded WOFF2 fonts, with a narrowly enabled data-font policy
for generated documents. JavaScript, external fonts and network access remain
blocked. D uses native MathML layout with bundled Fira Math glyphs and its
OpenType MATH table, plus the corrected local TeX fallback. C’s fonts, markup, CSS and cached documents remain unchanged. D's
new cache revisions retry old failed renders locally on the next open, using
the saved source without a mail fetch; successful prior documents stay reusable.

## Renderer provenance

Marked 18.0.13 remains **MIT** licensed, with its exact original copyright and
permission notice included. MathJax 4.1.3 and its TeX font data/WOFF2 fonts remain
**Apache-2.0**. Fira Math 0.3.4 remains **OFL-1.1**, with original font bytes
and full notices preserved. D-Mail's MPL does not replace these licenses. See
[third-party notices](../THIRD_PARTY_NOTICES.md) and the
[renderer source/build notes](../port/markdown-math/README.md).
The evaluated HarmonyOS `formula_hybrid` alternative is not shipped.

The HarmonyOS adapter explicitly copies numeric glyph tables to avoid observed
Ark runtime glyph mixing. CommonHTML must then run its original font-family and
combining-mark annotations; bypassing these caused clipped glyphs in the first
C preview. The corrected adapter retains those upstream annotations.

## Received timestamps

The original Swift IMAP date parser discarded positive timezone offsets.
For example, `16-Sep-2026 08:00:00 +0900` was treated as 08:00 UTC and then
displayed as 17:00 in Tokyo. The explicit
[port patch](../port/swift-imap/internal-date-offset.patch) preserves positive,
negative and fractional offsets. Formatting still uses the device timezone.

Existing cached header timestamps are corrected when refreshed from the server;
the app does not blindly subtract nine hours from every cached message.
Header updates preserve downloaded body files, attachment metadata and the
original body-retention timestamp.

## Validation

The earlier PNG installation is recorded separately in
[the historical validation record](markdown-math-validation.json).
The current C/D and source-only update is recorded in
[the current validation record](markdown-math-cd-validation.json).
Synthetic tests cover native C/D markup, visually inspected inline/display math,
source-only draft persistence, preview/back, renderer cache separation, no reader
refetch, optional failure, Markdown escaping and timezone offsets.
Private build/device evidence remains under ignored `.tools/`; production mail
is not part of these tests.

Installed in place on Pura X (VDE-AL00), version 1.0.1 / 1000001. Bundle and
storage identities were preserved; production was not launched. The signed
input hash was verified. The OS denied reading the installed HAP hash directly.
MatePad was not updated. Both renderer previews passed the isolated emulator
checks; emulator shutdown was independently verified. All 136 Swift tests passed.

## Equation-count limit removal

The user supplied a 17,941-byte document with 46 supported equations. Both
renderers previously aborted at the 32-equation cap. The count cap is removed;
the unchanged document renders all 46 equations in C and D within existing
size limits. A synthetic 96-equation test covers Markdown and HTML in both
modes. The user’s document and its rendered content stay in ignored local
evidence and are not included in the repository.

New rendering attempts use `math7:mathml:` / `math3:commonhtml:`. Successful
`math6:mathml:` / `math2:commonhtml:` documents remain reusable. Old failed
attempts can render once under the new revision without fetching mail; failures
under the new revision are still remembered. Font selection and C layout stay
unchanged.

This follow-up is installed in place on Pura X, still version 1.0.2 / 1000002,
with app/storage identities preserved and without launching production. The
signed build and installer success were verified; actual device appearance is
user-tested. See [limit-removal validation](markdown-equation-limit-validation.json).

The user subsequently requested MatePad installation. The same signed HAP is
now installed there too (MRO-W00), upgraded from 1.0.1 to 1.0.2 / 1000002 with
app/storage identities preserved and without launching production. Both devices
use the identical signed artifact recorded in the limit-removal validation.

## Copying equation source (installed on both devices)

Normal selection Copy includes each equation’s original delimiters and TeX
within the selected prose, in both C and D. A transparent selectable source
layer occupies the rendered equation’s area; visual glyphs are nonselectable.
The equation is a single selection unit. The source is escaped as text and
attributes, and original HTML entities are decoded exactly once. No clipboard
listener, JavaScript bridge or email script execution is enabled. Copying HTML
messages works when literal equation delimiters remain within visible text
spans. Code/preformatted blocks remain literal; equations split across tags or
already converted to images cannot be reconstructed by this renderer.

The copy feature uses new local cache revisions `math8:mathml:` and
`math4:commonhtml:` to regenerate older rendered documents with selectable
source. Original mail is retained and not downloaded again. Glyph fonts and
equation layout engines are unchanged.

Browser normal Copy was checked for complete paragraphs in C/D and an individual
MathML equation. Native selection may insert extra line breaks around inline
MathML equations; original TeX is intact. The MatePad probe could not reach its
isolated fixture, so native copying is not yet verified. Its isolated app was
removed and production was not accessed. The signed build is prepared, with
782 JavaScript and 40 Python checks passing. The user subsequently requested installation on both devices. The identical signed
1.0.2 update is installed in place on Pura X and MatePad, with app/storage
identities preserved and production not launched. Device copy behavior remains
user-tested.
See [copy validation](math-copy-validation.json).
