# 0.1.20 — automatic pictures and fixed message views

Opening an HTML message now prepares its pictures automatically before displaying
one settled local document. There is no Load pictures prompt. Browser resource
callbacks serve a fixed in-memory map; they cannot start downloads, read the
database or update the reader. Browser networking and sender scripting are blocked.

Saved attempts retain both successful pictures and failures. Reopening a saved
message, scrolling or returning from the background does not silently retry failed
pictures or reload a completed document. An incomplete view offers explicit Retry,
which downloads only missing pictures and replaces the view once the batch settles.
Good cached bytes and timestamps remain intact. Once all pictures are saved,
Retry and the warning disappear.

HTML picture planning covers image attributes, responsive sources, CSS backgrounds
and SVG image references. Entity decoding and Unicode URL encoding preserve
browser-compatible cache keys without rewriting signed query order or existing
percent escapes. Flag acknowledgements update metadata without replacing a body
being read or ending an unfinished body load early. Tablet split navigation,
combined header/body scrolling, quote disclosure, dark adaptation and links remain.

The existing Swift protocol clients deliver the body in one completed response.
This update does not bulk-download bodies during Inbox refresh, rasterize HTML or
automatically download separate attachments. Picture preparation is bounded to
256 distinct URLs, four concurrent downloads and 64 MiB of retained encoded data.
New requests stop starting after 30 seconds; active requests retain their existing
connection/read timeouts. Failed pictures cannot hold the message indefinitely.
See [snapshot behavior and limits](static-message-snapshots.md).

## Validation

All 477 JavaScript tests across 48 files and 13 Python tests passed. Host regressions
cover persistent attempts, cancellation, account deletion, resource limits,
Unicode URLs, immutable reader state and atomic retry replacement.

Production x86/ARM and isolated main/test HAPs built successfully. The isolated
reader matches 56 copied production files apart from explicit snapshot/link
counters; localized resources match. Swift libraries are unchanged from 0.1.19;
its Swift test results are prior evidence and were not rerun in this update.
Compile SDK stays at 26; target/minimum API and the native sysroot stay at 22.

The bounded emulator snapshot test used synthetic encrypted storage and loopback
HTTP. Held downloads kept the first Web absent until the batch settled; held Retry
kept the existing Web visible until one replacement was ready. Failed and complete
messages reopened with a newly created cache instance and no HTTP. The good URL
was requested once; each failed URL was requested only on the initial attempt and
two explicit retries, for counts of 1/3/3. Two non-content endpoints received zero
requests. Rapid swipes and simulated foreground transitions added no downloads or
document loads. Four screenshots verified original and recovered pixels with Web
networking blocked, and saved bytes/timestamps remained identical.

Native link taps reached the injected opener exactly once with query/fragment
intact; local anchors remained in the message. A 1,500-row, 233,428-unit HTML fixture
completed four drags over 12.45 seconds with one controller/document load, reached
1,443 vp offset and closed in 1.35 seconds including test-driver work. The isolated
app was removed and emulator shutdown independently verified. The first run stopped
at a test-only architecture check; replacing the unsupported test-shell query with
the platform ABI API allowed the final run to pass.

This verifies fixed application snapshots, rendering and cache behavior. It does
not establish the cause of the user's heat or measure battery savings. HTML layout,
image decoding and scrolling still consume CPU/GPU. No production mail or external
mail server was accessed. AppGallery packaging remains outside this update.

Development 0.1.20 (100020) is installed in place on Pura X and MatePad, in that
order. Device identities, installed versions and the matching signed artifact hash
were verified. Accounts were preserved and production was not launched.
See the [validation record](../port/mail-corpus/release-0.1.20-validation.json).
