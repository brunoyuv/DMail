# 0.1.27 — decoder termination and progressive pictures

A confirmed loop in the reused Swift MIME HTML-entity helper could keep a
message loading and consume CPU indefinitely. An ampersand without a later
semicolon took a `continue` branch without advancing the cursor. Both HTML
preview extraction and image-attribute rendering can reach the helper. A normal
unescaped query string such as `?a=1&b=2` is enough to trigger it. Cancelling the
Swift task does not interrupt this synchronous loop.

An explicit upstream port patch now walks Unicode scalars forward, preserves
unknown or unfinished entities literally and decodes completed entities. The
original MIME decoder, upstream source hashes and attribution remain intact.
Optimized synthetic preview and image-URL cases previously consumed one CPU core
until an external two-second watchdog killed them; after the patch they finish
in approximately 0.20 ms and 1.18 ms. A cancelled-task case also terminates.

The faulty helper was included in the original MIME integration, with a numbered
installation record as early as 0.1.1. The preserved 0.1.11 source contains it,
but its IMAP read path did not use the current HTML-preview call. Version 0.1.12
introduced HTML previews and is the earliest documented likely entry point for
that trigger. This distinction prevents attributing every earlier heat report
to this particular defect. The helper remained unfixed in 0.1.26.

## Reader changes

The selected-message loader returns the body and prepared HTML without waiting
for pictures. The reader mounts one HTML document immediately and completes its
pending local image responses as cached or downloaded bytes arrive. There is
one bounded picture attempt with four workers; no repeated HTML scan, JavaScript
injection or document reload. Completed cached attempts remain cache-only.
Hiding or backgrounding the reader cancels unfinished picture delivery and
pauses its WebView. A later explicit reopening can finish an interrupted attempt.

Visible body loading has a 45-second deadline covering queue/storage waits as
well as transport. Cancellation promptly releases the visible wait while owned
underlying work still drains safely. Refreshed flags no longer delay publication
of a downloaded body, and late flag results cannot overwrite newer operations.

Raw text and HTML files are validated independently within their existing 8 MiB
character limits. Their combined contents no longer pass through an 8 MiB JSON
metadata limit or repeated JSON copying. Legacy inline records retain their
existing limit. This fixes a separate rejection of individually valid body files.

## Validation and installation

All 654 JavaScript, 31 Python and 108 Swift MIME/body tests passed. Five new Swift
tests cover unfinished ampersands, ordinary image URLs, known/unknown/numeric
entities, Unicode, long malformed runs and cancellation. ARM and x86 native
libraries and HAPs rebuilt; the signed ARM artifact was verified and installed
in place on MatePad and Pura X without launching production or accessing mail.
Saved accounts are preserved. The emulator remained stopped.

Host tests exercise real renderer/cache/helper ordering with a mocked native
WebResourceResponse. Actual ArkWeb progressive-image rendering remains a device
acceptance check while the user tests the update. A passive numeric performance
capture accompanies the user's MatePad use; it records no mail, screenshots,
navigation or network contents. CPU and temperature counters are not per-app
power measurements, and the synthetic loop does not explain every heat case.

See [the validation record](../port/mail-corpus/release-0.1.27-validation.json).

The user confirmed that the previously stuck message opens with 0.1.27. The
passive capture has finished and its collector has exited. Before the user
backgrounded or locked the app around 18:16 JST, the attributed old app process
showed a median 93% machine CPU; afterward it showed zero during the valid
remaining samples. After installation, the separate process sampler measured
about 2.4% mean machine CPU over five minutes for the new process. These intervals
used different activity states and collection methods, exclude separately named
Web processes, and cannot establish battery savings or prove the source of all
heat. Missing process identities after installation were excluded, not treated
as zero CPU. Only numeric data was collected.
