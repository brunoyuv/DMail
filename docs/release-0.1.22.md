# 0.1.22 — finish every message in a synced mailbox

Sync now walks the remaining mailbox pages automatically and keeps unfinished
downloads in the encrypted database. The previous release only queued loaded
pages, silently stopped accepting messages after 200 entries, and considered
only the first 50 cached entries during an unchanged background check. Those
limits are removed. Restarting the app, switching accounts or interrupting a
scheduled job preserves pending message IDs, download stages and pagination.

Every protocol message ID gets its own saved body and attachment metadata, even
when an Inbox/Sent copy shares prepared HTML through Message-ID. Bodies and HTML
preparation take priority over pictures, so slow image hosts cannot prevent
later messages from receiving bodies. Automatic page discovery saves headers
without replacing the visible list or its navigation position. The first sync
after upgrading also registers existing cached rows and their saved cursor.

Completed bodies, HTML and picture attempts are reused with their original
timestamps. Transient failures retain durable backoff; invalidated pagination
returns to the mailbox head on a later sync. Foreground work pauses during
scrolling/backgrounding, and scheduled work rechecks its deadline and account
permission before new network requests. The reader stays local-only and fixed,
including broken pictures, with no rescanning, retry button or automatic reload.

This downloads all pages of mailboxes registered for sync; it does not silently
subscribe to every folder in every account. Existing protocol size/render bounds
and seven-day retention remain. Separate file attachments still download on
demand; attachment metadata and inline CID images are part of the body download.
See [sync behavior and bounds](static-message-snapshots.md).

## Validation

All 526 JavaScript tests across 52 files and 13 Python tests passed. New storage
tests persist 731 jobs through a store restart and test independent SQLite WAL
readers, transaction rollback, stale checkpoints and input ownership. Worker
tests finish 275 queued messages and cover automatic paging, interruption,
per-copy bodies, picture priority, retry persistence, stale server cursors,
permission revocation and overlapping workers. Inbox tests verify that refresh
feedback finishes without waiting for downloads and every cached member and
pagination cursor reach sync.

Production x86/ARM and isolated main/test HAPs built successfully. The test build
matches 61 copied shipping files apart from explicit counters; localized
resources match. Native Swift libraries are unchanged from 0.1.19; prior Swift
results were not rerun. Compile SDK remains 26, with target/minimum API and native
sysroot 22. Initial compilation caught unsupported ArkTS object spreads and a
nullable reference; both were corrected before the successful final builds.

The bounded native test uses the actual sync worker and encrypted AccountStore
with seven synthetic messages across three pages. It stops after two bodies,
closes the worker and database, reopens them and finishes all seven bodies and
documents before opening any message. Page positions are exactly 0, 3 and 6.
All bodies finish before the held picture batch. It then makes all sources
unavailable and reopens the store before displaying the reader. Opening,
scrolling, simulated foreground transitions and reopening add zero body
requests, scans, picture batches or HTTP. Counts remain seven body requests,
seven scans and one picture batch; each of three image endpoints receives one
request. Saved pixels, broken images, HTML, body bytes and timestamps remain
identical. The test passed in 26.50 seconds. The isolated app was removed and
emulator shutdown independently verified.

Development 0.1.22 (100022) is installed in place on Pura X, then MatePad. Both
device models, installed versions and the matching signed artifact hash were
verified. Saved accounts were preserved and production was not launched.
Device installation details and artifact hashes are recorded in the
[validation record](../port/mail-corpus/release-0.1.22-validation.json). No real
mail, provider account or external mail server was accessed. No battery or heat
measurement was made, and AppGallery packaging was not rebuilt.
