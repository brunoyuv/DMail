# 0.1.26 — file-backed messages, on-demand downloads and paced checks

The user confirmed that bodies should download when opened again. Mailbox sync,
account restoration, arrival hints and background checks no longer start or
resume the bulk body/picture downloader. Existing stored mail, prepared documents
and pictures remain available; old bulk-job rows are retained without a worker
draining them.

The explicit message loader first checks the raw cache. If needed, it downloads
that selected message using the original client, saves the result to the
originating account, prepares one fixed HTML document and finishes its initial
bounded picture attempt. Duplicate opens coalesce, obsolete queued opens are
cancelled, and navigation cannot publish another account's result. Completed
picture attempts never repeat. An interrupted initial picture attempt may finish
on explicit reopening without rescanning HTML. Optional HTML/picture failures
cannot hide a usable body. Body failures expose a direct Retry button.

Automatic checks and header followups share a serial process-local queue with
at least three seconds of rest after completion. Waiting uses a nonblocking
timer, with lifecycle and account permissions checked again before starting.
There is no timer for an empty queue. The configured checking interval and
foreground IMAP IDLE remain; this is not a new poll every three seconds.
Manual refresh, opening and sending remain outside the automatic queue. Tablet
split layout and the immutable reader are preserved.

## Message storage

The user selected readable text/HTML files in D-Mail's app-private persistent
storage. New raw text, raw HTML and prepared HTML use immutable `.txt`/`.html`
files. The encrypted database retains message metadata, flags, attachment
metadata, picture mappings and validated account-owned file references.
Header and flag updates preserve the references without opening or rewriting
body files. Existing picture-byte storage is unchanged.

The MatePad synthetic test exposed a native RDB limit: an oversized value can be
inserted but cannot be returned through the normal ResultSet window. The test's
20-picture HTML is about 6 MB. Legacy database bodies use bounded byte-chunk
reads, with UTF-8 reassembly and a final exact-value check, before migration.
Files are written completely and renamed before the database publishes their
references. Migration preserves body retention timestamps and cached content;
files stay in the app-private persistent directory rather than the OS cache
directory. A missing body file must trigger on-demand recovery, not a valid
empty message. The existing seven-day retention remains.

## Validation and profiling

All 647 JavaScript tests across 60 files and 28 Python tests passed.
The final profiler-parser correction was checked separately with its eight tests. Targeted
tests include actual UI methods with the new loader, original-account cache
ownership, obsolete selections, duplicate opens, Retry, optional picture failures,
background permission changes and cancellation during the automatic wait.
Both production HAPs compiled. Native Swift sources and libraries are unchanged
from 0.1.25; the original-client fixes and optimized native libraries remain.

A passive 15-sample SmartPerf capture of the already-running Pura X 0.1.25 app
produced 14 usable intervals, about 14.1 seconds after discarding the initial
sample. SmartPerf reported 10.49% interval-weighted app CPU on average and 23.36%
peak. Child-process CPU was unavailable. No production UI was operated and no
mail, screenshots, navigation trace or network capture was collected. The
user-controlled interaction state was unknown, so these data cannot establish
which code was active, a background-specific cause, or a power comparison.

The MatePad run passed in 85.3 seconds. It used 17 synthetic headers, one
6.18-million-character HTML message, 20 PNGs (800 × 450 each), 1,200 paragraphs
and 110 flings in 15 seconds at a requested 16,000 pixels/second. Idle, header
refresh, scrolling and background phases started no body or picture downloads.
Opening fetched one body and prepared its document once. Back/reopen and a real
AccountStore close/reopen worked with the synthetic body source sealed.

After saving, the raw-message database record was 804 bytes and the prepared
record was 215 bytes; full HTML lived in its private file. A disposable 3 MiB
row confirmed the native boundary: insertion succeeded and normal row access
returned no readable value. This reproduced a storage failure, not evidence
that every reported real-mail failure has the same cause.

SmartPerf collected 105 samples. All measured phases had complete time coverage.
The primary process was the `aa` test launcher; its reported child matched the
isolated app's main thread in HiPerf. These are the **observed app process**
means, normalized across the tablet's 12 reported CPU cores:

| Phase | CPU mean |
| --- | ---: |
| Idle Inbox | 0.034% |
| Header refresh | 1.701% |
| Opening the large fixture | 7.269% |
| Fast scrolling | 4.256% |
| Settling after scrolling | 0.528% |
| Background | 0.348% |

The settling/background averages include transition intervals; CPU fell further
near their ends. Opening still caused a one-time CPU/sensor burst. Test phases
include fixture actions, validation and settling, so their lengths are not pure
network or parsing timings. HiPerf captured 4,989 samples over eight seconds
with no lost samples. Its largest named rows were framework/system calls; this
sample does not establish a dominant mail-parser hotspot. Process coverage may
omit other ArkWeb processes, and no watt, battery-life or other-app comparison
was measured.

All 70 staged shipping source files, localized resources and ARM native library
matched production, apart from isolated counters. The test app was removed;
its process and HiPerf had stopped. The emulator was never started. No production
mailbox, message content, screenshot or network trace was accessed.

## Installation

Development 0.1.26 (100026) was installed in place on Pura X. Device identity,
version and signed artifact were verified; accounts were preserved and production
was not launched. At the user's subsequent request, the identical archived
signed artifact was also installed in place on MatePad, with model, architecture
and version verified. The user now operates that app personally during a bounded
numeric runtime capture; no production UI is operated by automated tools.
Swift libraries are unchanged from 0.1.25, whose 103
Swift tests are prior evidence rather than tests rerun for this update.

See [the validation record](../port/mail-corpus/release-0.1.26-validation.json).
