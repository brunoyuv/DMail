# 0.1.5 — repeated read/unread actions

Repeated read/unread changes stay available after background acknowledgement.
A temporary pending-cache caption clears when the confirmed cache becomes clean;
an actual offline fallback remains identified. Delayed completion callbacks and
conversation-index reads cannot overwrite a newer operation revision. Opening
a cached body uses its newest dirty state, so an earlier pending snapshot cannot
re-disable actions after completion.

The Unread filter opens an unread member of a conversation even when its newest
reply is already read. Filtering uses pending flag and folder overlays and
returns the list to the top, including after scrolling a long inbox. Tablet
split navigation and the existing visual design are retained.

The Swift IMAP flag path verifies the selected UID and UIDVALIDITY without
requiring optional UIDNEXT or message-count metadata. Unrelated unsolicited
FETCH responses are accepted alongside one explicit target FLAGS response.
Missing or ambiguous target flags, changed UIDVALIDITY and lost acknowledgements
still fail conservatively, without automatic retries. No message bodies or
optional STATUS requests are needed for these flag changes.

## Validation

- 129 host tests passed, including nine component regressions using production
  methods for cached-navigation races, repeated toggles and filtered threads.
- All 52 Swift host tests passed, including focused IMAP flag compatibility and
  original parser tests.
- ARM and x86 production builds passed. Signed ARM source and native-library
  parity was verified.
- Three native IMAP cases passed on the MatePad: 16 repeated changes across
  server-response variants and six conservative rejection cases. All 22 local
  sessions closed with zero violations, body downloads, STATUS queries or retries.
- Pura X VDE-AL00 and MatePad MRO-W00 were both upgraded in place to
  0.1.5 (100005); installed bundle versions and the signed artifact hash match.
- The first isolated native UI attempt stopped in test-window startup before
  it reached the inbox or captured any screenshot. After fixing test-window
  lifecycle handling, three top filter cycles passed with zero service calls;
  the synthetic screenshot shows the older unread conversation member.
  The longer scroll phase stopped waiting for a fixture row. Bottom-scroll and
  native reader-opening checks remain unverified; no full native UI pass is claimed.
- The isolated test application was removed, local fixture sessions and port
  forwards were closed, and the emulator remained stopped.

Full [validation record](../port/mail-corpus/release-0.1.5-validation.json).

Real-provider validation remains user-operated. Automated checks use synthetic
mail only, and installation preserves accounts without launching production.
