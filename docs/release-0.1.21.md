# 0.1.21 — download messages during sync

Mailbox sync now downloads message bodies and pictures without opening them.
This corrects 0.1.20, which started picture preparation when a message opened.
The reader shows the saved HTML and available picture bytes, including broken
pictures. It never scans for pictures, fetches a body, retries a picture, or
replaces the open document when sync finishes. The picture warning and Retry
button are removed.

New mailbox pages, initial cached pages, arrival refreshes, pagination and
Inbox/Sent companion pages feed a bounded sync queue. Header refresh feedback
finishes before body and picture work. Bodies download serially through the
existing mail clients. Sync prepares and saves each HTML document once, before
its picture batch; later syncs reuse the saved document and completed picture
attempt, including failures. Existing fresh bodies are retained. Scheduled jobs
can do the same work within their deadline and current account settings.

Opening reads local storage once and gives the browser a fixed resource map.
If a download finishes while a message is open, that view stays unchanged.
Reopening can show newly cached bytes without scanning or downloading. A body
that has not been downloaded shows a pending-sync message. Legacy cached HTML
can still display without reader-side migration. Tablet split navigation, links,
quote disclosure and native dark adaptation remain.

The existing seven-day retention and on-demand separate attachments remain.
See [sync behavior and bounds](static-message-snapshots.md).

## Validation and installation

All 504 JavaScript tests across 51 files and 13 Python tests passed. Regressions
cover immutable encrypted documents, independent SQLite readers, cache-only
opening, nonblocking Inbox refresh, sequential body downloads, cancellation,
foreground resume and bounded background job permissions.

Production x86/ARM and isolated main/test HAPs built successfully. The isolated
build matches 59 copied shipping files apart from explicit test counters;
localized resources match. The native Swift libraries are unchanged from 0.1.19,
so its Swift test results are prior evidence, not a new run. Compile SDK remains
26; target/minimum API and the native sysroot remain 22.

The bounded emulator test used the actual sync worker, encrypted AccountStore
and reader with synthetic mail and loopback pictures. Sync saved a body and
prepared HTML, with one good and two failed pictures. All sources were then
made unavailable and the store reopened before the first reader opened.
Opening, scrolling, foreground transitions and reopening added zero body
requests, HTML scans, picture batches or HTTP requests. Total body/scan/batch
counts stayed at 1/1/1; each picture endpoint was requested once. Both openings
rendered the original saved pixels and broken pictures. Saved HTML, bytes and
timestamps stayed identical. No reader Retry, picture warning or loading view
appeared.

Native link taps reached the injected opener once with query and fragment intact;
local anchors stayed in the document. The 1,500-row, 233,428-unit reader completed
five drags over 13.20 seconds with one controller/document load, reached 1,792 vp
offset and closed in 1.08 seconds including test-driver work. The first native
run stopped before the fixture because its startup monitor missed an already
created test ability. Using the current test ability with one monitor fallback
fixed the harness; the final bounded run passed. The isolated app was removed
and emulator shutdown independently verified.

Development 0.1.21 (100021) was installed in place on Pura X, then MatePad. Device
models, installed versions and the matching signed artifact hash were verified.
Accounts were preserved and production was not launched. No real mail or external
mail server was accessed. AppGallery was not rebuilt. These tests establish the
saved-view behavior; they do not measure battery savings or establish the heat
cause. Native HTML layout, image decoding and scrolling still use CPU/GPU.

See the [validation record](../port/mail-corpus/release-0.1.21-validation.json).
