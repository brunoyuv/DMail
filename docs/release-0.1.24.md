# 0.1.24 — reduce sync work and recover missing bodies

The shipping Swift IMAP, NIO and TLS dependency objects were compiled without
optimization. Shipping builds now select release objects and reject a build plan
that contains unoptimized dependencies. The original Thunderbird clients remain
in use. A controlled host IMAP parser benchmark produced identical results with
median CPU time reduced from 0.876259 seconds to 0.104121 seconds, about 88% less.
This measures synthetic parser work, not whole-app battery use.

The user dates the battery increase to development builds around 0.1.11, before
Google sign-in was removed and before separate D-Mail packaging. The retained
pre-publication source already selected debug IMAP objects. Automatic complete
body/picture sync was introduced later, in 0.1.21–0.1.22, so it cannot explain
that earlier onset by itself. Version 0.1.11 was reused across several source
changes; the records do not identify the precise build or prove a battery cause.

Body sync now reuses a bounded original Swift IMAP connection instead of creating
a new TLS connection and logging in for every message. Sessions allow at most
16 reads, 60 seconds total and 15 seconds idle, with exclusive ownership and a
four-session limit. Credentials remain bound to the exact endpoint, login and
authorization. Pausing or closing sync releases its sessions. Failed exchanges
are closed rather than replayed immediately. SMTP, mutations and IDLE use their
existing paths.

Picture-cache saves no longer return and sort the entire account's picture
inventory for each downloaded image. A scalar size query checks the budget, and
only an over-budget save reads the oldest eviction candidates. The existing
account, retention and transactional guards remain.

Two synthetic reproductions explain ways bodies could stay unavailable:

- A failed request recorded a retry deadline, but the worker never scheduled a
  wake for it. Restarting before that deadline could leave it pending indefinitely
  in a quiet mailbox. One timer now wakes for actual unfinished work; empty and
  completed queues have no polling timer. Pause, thermal limits and background
  deadlines still apply.
- A native decode failure with neither text nor HTML could be cached as a fresh
  body, prepared as empty HTML and marked complete. A later header sync retained
  that blank state. Recovery is limited to failed empty records; successfully
  saved bodies and settled picture attempts retain their existing behavior.

An explicitly selected pending message can check local storage again after sync
finishes. Once a body is open, its document remains fixed. Opening never starts a
body or picture download. Tablet split view is preserved.

## Validation

All 572 JavaScript tests across 54 files and 20 Python tests passed. The Swift
IMAP/SMTP suite passed 97 tests in 30 suites, including eight new TLS session
lifecycle tests. The final native bridge additionally tests empty-body
classification. Worker and migration tests cover persisted retries, deadline
races, pause/close, malformed queues, interrupted transactions and concurrent
successful body replacement through separate SQLite WAL readers.

Both native architectures and production HAPs built successfully. The isolated
main/test build matches 65 shipping source files apart from explicit counters,
with matching localized resources and native-core hashes. Compile SDK remains
26, with target/minimum and native sysroot API 22.

The shipping native bridge read the same three Unicode messages over three
ordinary TLS/authentication sessions and one reused sync session, with identical
bodies and metadata. Changed credentials and a retired session ID opened no
extra connection. Six additional cases distinguish zero-byte text/HTML and
attachment-only mail from invalid UTF-8 and missing advertised text, while
preserving the existing fallback for a malformed Base64 declaration. Every
connection closed. An initial fixture expectation incorrectly rejected that
fallback; correcting the fixture required no production decoder change.

The actual encrypted Harmony RDB also repaired a seeded 0.1.23 failed-empty
record while preserving its summary, flags and attachment metadata. A valid
partial message/document remained byte-identical. A second initialization made
zero repair writes.

The visible native Inbox saved 16 bodies/documents, then added zero sync queries,
scans or requests over 10 seconds. One header arrival and scrolling settled
without body downloads. The native picture test restarted its worker and
encrypted database after two bodies, completed all seven messages across three
pages, and opened with the source offline. Opening, scrolling and reopening
added no scans, picture batches or HTTP. Original pixels and broken pictures
remained fixed. Both checks passed, the isolated app was removed and emulator
shutdown was independently verified.

Development **0.1.24 (100024)** is installed in place on Pura X and MatePad.
Models, versions and matching signed artifact hashes were verified; accounts
were preserved and production was not launched. See the
[validation record](../port/mail-corpus/release-0.1.24-validation.json).
These tests establish bounded synthetic behavior and specific repairs, not the
exact historical battery cause or physical-device energy savings. No real mail
or provider account was accessed; AppGallery packaging was not rebuilt.
