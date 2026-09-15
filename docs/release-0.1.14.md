# 0.1.14 — responsive refresh and picture diagnostics

Refreshing previously disabled every message row until Inbox and companion-folder
work completed. A cached message could not open through the disabled native row,
even though the reader already supported asynchronous navigation. Starting a
refresh also switched off native pull recognition during the gesture.

Rows now remain available while headers load, and native pull recognition stays
stable. Opening a reader retires the old refresh's UI ownership: late metadata,
headers and spinner cleanup cannot replace the new navigation or clear a newer
operation's loading state. A separate unavailable-cache retry loop previously
repeated local reads every 250 ms; it now uses the existing ten-second backoff
and stops after three attempts. Synthetic tests reproduce these defects. Device
heating was reported, but its cause has not been measured or established.

The previous picture fix covered PNG/JPEG/GIF/WebP served with generic or missing
MIME types. This update also canonicalizes recognizable raster bytes with an
incorrect image subtype, recognizes remote pictures in escaped CSS, CSS image-set
and SVG image references, and lets sender-authored CSS heights override the
responsive default. A native comparison reproduced a visible broken-image icon
from an inline-styled 1 × 1 image when the previous forced height expanded it.
That is a possible explanation for the supplied screenshot; the screenshot does
not identify the original resource, dimensions or transport failure.

Picture refresh keeps the existing cached image if its replacement fails. A
localized summary now distinguishes connection, HTTP status, format, size and
storage failures without displaying resource URLs or provider responses. The
status and legacy cache APIs share requests, including one queued explicit retry.
Generated document resources are blocked locally instead of entering picture
network requests and failure summaries. Inline images, consent, offline retention
and existing request limits are preserved.

## Validation

All 337 JavaScript tests and nine Python tests passed. New deferred-response
regressions verify cached and uncached opening during refresh, stale-result
ownership and bounded missing-cache retries. Alias MIME error-page regressions
verify that bad replacements retain saved bytes, MIME, timestamp and consent.

Native phone and tablet landscape gates passed (41.475 s and 38.708 s). Both held
a synthetic refresh unresolved, scrolled the Inbox and opened a cached reader
before releasing the response. The reader and cache stayed intact afterward,
with exactly two Inbox page requests and no body or other mail requests. The
tablet retained its split view. The final native picture gate passed (16.431 s),
including no false failure summary after a successful image, correct HTTP 503
summary, request coalescing and retained visible cached pixels after failures.
Native transport and authored-height comparison gates also passed. The emulator
stopped after each bounded session; native-process absence was verified.

Production x86, signed ARM and isolated main/test packages built using CLI
26.0.0.821, Hvigor 6.26.4 and SDK 26.0.0.105. Source parity was verified for the
changed UI and picture files. The Swift protocol clients are unchanged in this
release. Development 0.1.14 (100014) was installed and metadata/hash-verified on
Pura X and MatePad through in-place upgrades, preserving accounts and leaving
production closed. The separate AppGallery package was not rebuilt.

Automated checks used synthetic accounts, bytes and local servers only. No
production mailbox access, physical mail capture or sending occurred. See the
[machine-readable evidence](../port/mail-corpus/release-0.1.14-validation.json).

Signature checks identify common formats rather than fully decoding them. The
new summary diagnoses download/cache failures, not every later ArkWeb rendering
failure. Exact causes of other pictured failures remain unknown without the
resource or a diagnostic from the updated renderer.
