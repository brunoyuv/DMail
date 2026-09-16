# D-Mail 1.0.3

Version **1.0.3**, code **1000003**.

## Changes

- Normal selection Copy retains original TeX and delimiters, including equations
  within selected paragraphs, for both CommonHTML and native MathML.
- Old generated math documents are regenerated once from local message content
  to add selectable source. This does not request the body again.
- Removes the equation-count cap that prevented longer Markdown documents from
  rendering. Input, per-expression and output-size safeguards remain.
- Includes the 1.0.2 Fira Math renderer, with corrected TeX fallback for missing
  glyphs. CommonHTML retains its existing font and layout.
- Updates the README and installs pinned math/font dependencies in host-test CI.

Mail scripts remain disabled. Sending keeps original Markdown/TeX source.
Marked retains MIT, MathJax retains Apache-2.0, and Fira Math retains OFL-1.1.

## Validation and limits

The feature snapshot passed **782 JavaScript and 40 Python tests**. Browser
normal-Copy checks preserved equation source in both renderers and copied an
individual MathML equation exactly. Native MathML selection can insert extra
line breaks. The isolated MatePad probe did not reach its fixture, so native
clipboard behavior remains unverified. See [copy validation](math-copy-validation.json).

The long-document regression covers 96 synthetic equations in Markdown and HTML
under both renderers. The user-provided document rendered all 46 equations; it
is excluded from public source and packages. See
[equation-limit validation](markdown-equation-limit-validation.json).

The same feature snapshot was previously installed in place on Pura X and
MatePad under version 1.0.2, preserving app/storage identities without launching
production. The 1.0.3 release package has not been installed or device-tested.

## Upload artifacts

The AppGallery variant uses **some.DMail.hamorny**, separate from the development
identity **org.thunderbird.harmony.dev**. Use the standalone release-signed APP
for AppGallery; its SHA-256 and signature-verification sidecars identify the
exact source revision. The companion GitHub ZIP includes matching source,
notices and unsigned build artifacts for reproducibility. Release signing uses
the existing matching release key/profile, never device debug signing.

Build and signing results are recorded beside the artifacts in ignored `dist/`.
See [release packaging](release-packages.md). Store upload and acceptance are
separate from local build/signature verification.
