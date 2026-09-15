# 0.1.23 — stop repeated Inbox sync work and pace the backlog

A saved document with an invalid future timestamp could prevent its replacement
while the sync worker repeatedly moved the same cached message between body and
picture stages. In a synthetic 100 ms reproduction, this caused 260 HTML scans
and 1,820 sync/document queries with no network request or progress. The repair
guard reduced that case to one scan and 11 queries, then completion. Other
unusable document commits now retain durable backoff instead of cycling.
Valid fresh documents remain immutable.

An incomplete mailbox also kept downloading and preparing messages continuously.
Bulk sync now rests between items, with a minimum of 250 ms and additional rest
based on the preceding work duration. At thermal level NORMAL it rests longer;
WARM or hotter pauses new bulk work until the platform reports cooling. The
shared thermal listener closes with the last worker. A missing platform thermal
API falls back to ordinary pacing. No idle or retry polling timer is added.
See the [official thermal API](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-basic-services-kit/js-apis-thermal.md)
and [sync behavior](static-message-snapshots.md) for the exact limits.

All queued IDs and mailbox pagination remain durable, with no admission cutoff.
Pausing, background deadlines and closing preserve unfinished work and cancel
the rest timer. Repeated wake events cannot bypass the rest. Header refresh does
not await this work. Initial preparation of a large offline mailbox can take
longer, while the reader remains local-only with fixed HTML and saved pictures.
Tablet split view is unchanged.

## Validation

All 542 JavaScript tests across 53 files and 13 Python tests passed. Worker tests
still complete all 275 queued bodies; new tests cover repair/backoff, pacing,
repeated wake events, thermal pause/resume, deadlines, cancellation and restart.
Seven thermal-helper tests cover shared ownership, stale/invalid callbacks,
cleanup and unavailable APIs. Prepared-document tests include independent SQLite
WAL readers and clock-rollback repair.

Production x86/ARM and isolated main/test builds passed. The isolated build
matches 63 shipping files apart from explicit test counters, with matching
localized resources. Native Swift libraries are unchanged from 0.1.19; those
Swift tests are prior evidence, not a new run. Compile SDK remains 26, with
target/minimum API and native sysroot 22.

The bounded native Inbox test kept the actual ConnectedMail view open while
saving 16 synthetic bodies and prepared documents. Consecutive body requests
were at least 264 ms apart; the first-to-last interval was 4,675 ms. After
completion, 10,001 ms added zero sync queries, scans, picture batches, body
requests or page requests. One synthetic arrival and a scroll produced one
header request and no repeated body preparation, then settled again. These
counters measure sync work, not every UI/cache query or process CPU usage.

The native saved-picture check also passed: a worker/database restart after
two of seven bodies retained the backlog, and all seven bodies across three
pages finished before opening. Opening, scrolling and reopening offline added
zero scans, batches or HTTP. Original pixels and broken pictures stayed fixed.
The checks took 29.36 and 28.44 seconds. The isolated app was removed, and
emulator shutdown was independently verified.

Development 0.1.23 (100023) is installed in place on Pura X, then MatePad. Device
models, installed versions and matching signed artifact hashes were verified.
Saved accounts were preserved; production was not launched. See the
[validation record](../port/mail-corpus/release-0.1.23-validation.json).

The repeated-work reproduction is a confirmed synthetic defect, not proof of
the user's exact heat cause. Host CPU counters and emulator operation counts
are not device energy measurements. No real email or provider account is used
in these checks. AppGallery packaging is not part of this development update.
