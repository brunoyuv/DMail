# 0.1.13 — pictures served as generic binary files

Some newsletter pictures contain valid PNG data but arrive with
`Content-Type: application/octet-stream`, often at URLs without an image
extension. The picture cache previously rejected those responses, so repeated
refreshes could never display them. The loader now recognizes PNG, JPEG, GIF and
WebP signatures when the server supplies a generic or missing content type. It
displays and stores the bytes with the corresponding image MIME type.

Explicit non-image responses and unrecognized binary data remain blocked.
Existing image-format validation, per-message consent, offline reuse, retention,
download limits and failed-refresh fallback remain in place. No server-specific
URL rules or additional network requests were introduced.

The cause was verified from the exact newsletter link supplied by the user:
two reported article pictures returned HTTP 200 with PNG signatures and a generic
binary MIME type. The supplied page, screenshot and URLs stay in ignored local
files. Automated tests use synthetic content only, with no mailbox access.

## Validation

Three new host regressions failed against the previous loader and passed after
the fix. All 314 JavaScript and nine Python tests passed. They cover generic and
missing MIME headers, PNG/JPEG/GIF/WebP recognition, canonical MIME persistence,
offline reopening, successful replacement and retention after invalid responses.

The bounded native emulator test passed in 17.723 seconds using the shipping
renderer and picture cache, byte-for-byte, with diagnostics disabled. A loopback
server returned fresh and replacement synthetic PNGs as `application/octet-stream`.
The test checked visible image pixels, exact persisted bytes and `image/png` in
the encrypted cache. Two subsequent HTTP 503 failures retained the replacement
picture, its timestamp and consent; repeated pending refreshes coalesced. The
renderer used `fitContent` inside a Scroll, matching the message reader.
The emulator stopped automatically and native-process absence was verified.

Production x86, signed ARM and both isolated test packages built with CLI
26.0.0.821, Hvigor 6.26.4 and compile SDK 26.0.0.105. Target/minimum and the Swift
native sysroot remain API 22. This change does not alter the Swift mail clients.
The separate AppGallery package was not rebuilt.

Development version 0.1.13 (100013) is installed and metadata/hash-verified on
Pura X and MatePad. Both received the same signed HAP through in-place upgrades,
preserving saved accounts; production was not launched. The phone's stale Wi-Fi
debugging session was reconnected before installation. See the
[machine-readable evidence](../port/mail-corpus/release-0.1.13-validation.json).

Image signature checks identify these raster formats; they are not a full image
decoder. Remote servers can still fail, and failed refreshes preserve any usable
cached picture.
