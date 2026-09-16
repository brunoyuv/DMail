# 1.0.2 — Markdown, math and received timestamps

Version 1.0.2 (1000002) adds per-account optional Markdown/TeX rendering when
reading mail and a local composer preview. Settings offers native MathML (D,
the default) and MathJax CommonHTML (C). D uses Fira Math throughout equations,
with original OpenType layout metrics and a bundled corrected TeX fallback for
missing glyphs. C retains its original fonts and layout. The reader accepts the
bundled OTF and WOFF2 data fonts only for generated math documents, within the
existing per-font size limit.

Messages are sent as their original Markdown/TeX text; outgoing formatted HTML
is not enabled. Saved drafts and received source remain intact. Rendering uses
separate local cache keys (`math6:mathml:` and `math2:commonhtml:`), so reopening
old D documents regenerates their presentation without downloading mail again.

The original Swift IMAP date parser now preserves positive timezone offsets,
including fractional hours. The reported +9-hour display error is corrected on
fresh or refreshed headers, without blindly shifting unrelated cached dates.

Marked retains its MIT license, MathJax and its TeX fonts retain Apache-2.0,
and Fira Math retains OFL-1.1. Original notices, source hashes and the explicit
Swift port patch are included. App identity, accounts and native ABI names are
unchanged. No remote push or public publication is part of this release.

All 779 JavaScript and 40 Python tests pass. Twenty-two C markup/CSS comparisons
remain identical. The signed ARM HAP compiled and passed source/package checks.
It is installed in place on Pura X with app/storage identities preserved and
without launching production. MatePad remains unchanged. Fira was visually
checked in the desktop browser; its actual device appearance is not yet verified.
Validation and package hashes are recorded in `release-1.0.2-validation.json`.
Prior controlled newsletter tests did not reproduce the user's stuck-message
failure; this release does not claim a fix for that unconfirmed cause.
