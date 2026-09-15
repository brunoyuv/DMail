# 0.1.18 — attachment names, links and bounded reader work

This update preserves Unicode PDF attachment names, decodes RFC2231 filename
parameters and common RFC2047 encoded names, and retains safe filenames when
opening/saving them. Unicode is encoded safely when MIME is reconstructed; long
local names are limited by UTF-8 bytes without cutting a character or .pdf.

User-tapped HTTP/HTTPS links go through the platform browser API. New-window
links use the same intercepted path, local anchors stay inside the message,
and explicit web URLs in plain-text mail become links. Unsolicited navigation
and non-web schemes remain blocked. Launch errors use a fixed translated message.

The reader prepares HTML once per body/language, reusing it across picture
retries and inset changes. Repeated unchanged property notifications no longer
reset the document, blocked picture consent does not cause a second full load,
and completed readers remain intact through foreground transitions. Unfinished
picture/document work still resumes from cache. These changes avoid repeated
parsing and layout of long mail; physical thermal improvement is not yet measured.
The existing tablet split layout and single scrolling reader are retained.

MIME rendering preserves alternative/related body selection and scoped CID/
Content-Location resources. Image replacement matches complete image references,
not prose or URL prefixes, and limits total base64 expansion without cutting a
data URI. Recognized generic PNG/JPEG/GIF/WebP parts can appear inline. A narrow
compatibility fallback keeps malformed MHTML with one declared body readable.
Cached message bodies and saved pictures are not invalidated: corrected MIME
output and previously lost attachment names apply on the next body fetch.

Optional IMAP folder counts share a five-second budget, with at most two seconds
per STATUS and no further count commands after failure. Successful operations
allow one second for LOGOUT; failed operations shut down without extra protocol
work. The original result is preserved, so a failed logout cannot change a
confirmed flag operation into failure or cause a retry. Unread aggregation
avoids repeated projection of overlapping folder headers.

## Validation

All 453 JavaScript tests across 45 files and 9 Python tests passed. Clean Swift
builds passed 89 IMAP tests/29 suites and 100 MIME tests/23 suites. Both native
cores were rebuilt without incremental derived objects after the MIME layout
change. Production x86/ARM and isolated main/test HAPs built successfully.

Native OAuth(7), encrypted storage(1), and picture cache(1) tests passed in the
bounded emulator. Successful pictures survived two failures, recovery and reopen
with the fixture server returning 503; reopening issued zero requests. The
emulator shut down and its native process was separately verified absent.

The initial combined link/long-scroll fixture passed links but failed to prove
outer scrolling. The final fixture matched the production container layout,
corrected shared scene ownership, clamped gestures to the visible screen and
recorded geometry. The user then authorized the MatePad for this final test.
On the physical MatePad, links and local anchors passed, followed by 1500 rows
(233428 UTF-16 units), 6 real drags over 11,558 ms, 1,686 positive scroll callbacks,
and 1,952.37 vp maximum offset. Controller/document load counts stayed 1/1;
no document reload occurred during scrolling. Native Close completed in 1,602 ms,
including test-driver overhead. Synthetic before/after screenshots were inspected.
The isolated test app was removed. All 52 copied shipping files matched apart
from two explicitly isolated counters, and the ARM core matched the shipping one.

See [machine-readable validation](../port/mail-corpus/release-0.1.18-validation.json).
Development 0.1.18 (100018) is installed in place on Pura X and MatePad.
Bundle versions and the matching signed artifact hash were verified. Saved
accounts were preserved; production was not launched.
Production mail was never launched, read or sent by the tests.

## Long-document investigation

The confirmed 0.1.11 snapshot and current reader both use one expanded WebView,
FIT_CONTENT, synchronous rendering and the same outer native Scroll. No new
per-scroll callback or CSS layout loop was identified. A 2M-character table
fixture took 32.74 ms for initial host preparation in 0.1.11 and 51.82 ms in the new
version; the new prepared-body cache performed only one transformation across
seven calls including picture-permission changes. These V8 timings exclude
ArkWeb rendering, native string transfer, GPU work and device temperature.

There is no documented public app-wide CPU percentage cap found for Pura X or
MatePad. TaskPool priorities/concurrency apply to worker tasks; thread QoS changes
scheduling priority rather than imposing a quota. Background process suppression
only covers app-created native children, and process power-saving mode is for
PC/2in1 devices. No such permissions or controls were enabled. Sources:
[Huawei QoS overview](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/kernel-enhance-overview),
[process management API](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-backgroundprocessmanager).
The retained long-reader mode follows [ArkWeb FIT_CONTENT guidance](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/web-fit-content).
