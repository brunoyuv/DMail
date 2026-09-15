# 0.1.15 — responsive refresh and less repeated work

Dragging the Inbox during a pending refresh could dismiss HarmonyOS's spinner
without completing the request. The app treated that visual state as the request
state, disabling swipe actions and allowing search to resize the list during the
gesture. Request ownership is now independent of spinner feedback. Scrolling,
read/star actions and opening cached mail remain available while headers load;
late responses cannot replace the reader or a newer account operation.

The review also removed repeated full-folder scans and unnecessary HTML body
copies. Header lists use metadata-only cache reads while the reader retains its
full offline body. Composer and Settings share a bounded autosave queue, with
explicit save, send, account-switch and teardown boundaries. Recipient history
updates only changed records, and local Sent reconciliation shares one index per
page. Attachment operations use asynchronous file I/O, share duplicate work and
protect active temporary files from cleanup.

Additional fixes guard stale account and conversation completions, preserve
pending saves through close/reopen, stop canceled notification work before another
request, suppress repeated identical IDLE arrival hints, and coalesce pending
badge updates. SMTP acceptance remains successful if later connection cleanup
fails; accepted-message persistence attempts both local copies independently.
No automatic resend is introduced.

## Validation and installation

- 411 JavaScript tests, nine Python tests and 14 Swift host tests passed.
- Native phone and tablet tests used 2,000 synthetic cached headers and a held
  server response. Both scrolled upward/downward, acknowledged read and star,
  and opened a cached reader before releasing the response: one client, one page,
  two flag operations, and zero body or other mail requests.
- Native storage, tablet search/spinner/split presentation and picture retry
  gates passed. Failed picture refresh preserved visible cached pixels and
  consent. Five native gates passed in total; screenshots were inspected.
- Production x86, signed ARM and isolated main/test builds passed with SDK 26,
  retaining target/minimum API 22. Shipping source/native-library parity passed.
- Development 0.1.15 (100015) was installed on Pura X and MatePad in place.
  Device models, installed versions and the signed package hash were verified.
  No app data was cleared and production was not launched. Every emulator
  session stopped after its bounded synthetic test.

The complete [review and coverage record](review-performance-2026-09.md) links
the storage, notification and protocol findings. The [validation record](../port/mail-corpus/release-0.1.15-validation.json)
contains artifact and evidence hashes. Tests used synthetic data only; no real
mailbox access, physical mail capture or sending occurred. AppGallery was not
rebuilt.

These checks establish functional responsiveness under stalled requests and
reduced work counts, not measured frame rate, temperature or battery life.
Ordinary native requests still incur connection setup, and some IMAP transport
failures can still be mislabeled as requiring authentication. MIME/CID edge cases
and the unidentified missing picture remain documented follow-ups. The review
does not claim that every possible defect has been eliminated.
