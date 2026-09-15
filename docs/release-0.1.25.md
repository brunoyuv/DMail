# 0.1.25 — recover messages stuck pending

This follow-up addresses the report that a message still says it has not
downloaded after returning to the Inbox, refreshing and reopening it. Three
synthetic reproductions identified separate defects.

- An interrupted scroll could leave the Inbox's interaction flag set after its
  list was hidden. The body worker then stayed paused through subsequent
  refreshes. Navigation visibility and background transitions now retire those
  interrupted gestures. A visible tablet list keeps its real scrolling pause;
  the split layout and sync pacing are unchanged.
- A failed empty body could be repaired while an older completion timestamp
  left its job marked done. Registration now requeues a completed job when its
  exact raw-cache row is absent or its canonical metadata explicitly says the
  body is pending. The check reads at most 192 metadata characters inside
  SQLite. It does not transfer or parse saved bodies, replace valid prepared
  documents, or repeat completed picture downloads. The initial failed-body
  repair also handles differing completion timestamps.
- The original Swift IMAP fetch handler replaced earlier attributes when a
  server split them across FETCH responses. MIME headers or body bytes could
  disappear. Responses now merge within the same sequence number with UID
  conflict checks. Selective body reads choose the requested UID even when
  unrelated flag updates arrive. Ambiguous identities still fail, and bytes
  are never borrowed from another message.

Opening a message continues to use local storage only. Saved HTML remains
fixed, and the reader does not scan, reload or download pictures. These fixes
preserve seven-day body retention, transfer limits, retry backoff and thermal
pauses. They establish specific synthetic failure and recovery paths; no real
mail was inspected to identify which path affected the user's devices.

## Validation

All 580 JavaScript tests across 55 files, 20 Python tests and 103 Swift tests
across 31 suites passed. Both native architectures and production HAPs rebuilt
successfully. The signed ARM package passed source/library verification.

At the user's request, **0.1.25 (100025) was installed on Pura X first** for
their own testing. The device model and installed version were verified. The
in-place upgrade preserved account storage and production was not launched.
MatePad remains on 0.1.24. The additional synthetic native tests for split FETCH,
encrypted-database registration recovery and navigation are prepared but have
not been built or run for this update. The emulator remains stopped.
See the [validation record](../port/mail-corpus/release-0.1.25-validation.json).
