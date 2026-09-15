# Bounded follow-up review

The user limited the remaining bug, simplification and efficiency review to at
most three rounds. Count the batch active when the limit arrived as round 1.
Stop after round 3 at the latest; finishing earlier is allowed. Do not open
additional review work after these gates. Existing unrelated worktree changes
and the installed 0.1.17 baseline must be preserved.

1. **Complete:** finish the newly requested UTF-8 PDF filename and hyperlink
   fixes; integrate the already-started IMAP optional-work cleanup, unread
   aggregation reduction and MIME inline-image correctness work. Use synthetic
   fixtures, preserve original Swift clients/attribution and existing UI style.
2. **Complete; one native gate needs correction:** build and validate the integrated result with focused host and
   bounded native tests. Correct defects found by these gates. Install the tested
   update in place on the two authorized devices without opening production.
3. **Complete — review stopped:** resolve remaining regressions in this batch, repeat affected
   gates, perform the completion audit and stop. Report unresolved limitations
   without extending the review into another round.

Every round must record concrete changes, test evidence and any remaining work.
The cap changes the review duration; it does not authorize skipping required
validation or claiming a fix without evidence. No real mail may be read or sent.

## Round 1 evidence

Filename/header parsing and file-path handling, native browser link routing,
scoped MIME image reconstruction, unread aggregation and IMAP optional work are
implemented. The integrated MIME suite passed 100 tests; a clean IMAP rebuild
passed 89 tests in 29 suites, including six local TLS cleanup scenarios and 19
authentication scenarios. JavaScript/Python gates passed 448/9 before the final
long-HTML additions. Installed 0.1.17 artifact/source were archived before staging.

The user then clarified continuous scrolling through very long HTML as a likely
trigger. This investigation remains inside round 2, not a new review cycle.
Comparison with confirmed 0.1.11 source found the same one-WebView/FIT_CONTENT
layout. Current renderer now avoids repeated same-property/finished-resume
reloads, omits a second load for unchanged blocked picture consent, and prepares
HTML once across picture retries. 31 renderer tests pass. Native continuous-scroll
and link-tap checks are prepared alongside existing cache/protocol gates.

## Round 2 evidence and final gate

Both native cores were rebuilt from clean derived build trees. All four HAPs
built; 52 copied shipping source files match the isolated app after removing
its two explicit counters. Full host gates passed 453 JavaScript/9 Python tests.
Native OAuth (7), storage (1), and picture-cache (1) checks passed. Link dispatch
and local anchors passed inside the final combined gate, but its subsequent
continuous-scroll assertion failed because the outer Scroll reported no verified
movement. No production fix is inferred from this yet. The wrapper stopped the
emulator and a separate process check confirmed absence.

Round 3 is limited to diagnosing/correcting this prepared gate, rerunning affected
native checks, installing the tested changes and recording limitations. No more
review scope follows it. Installed devices remain 0.1.17 until upgrade verification.

## Round 3 completion

The test fixture now matches the production containers, retains scene ownership
through late teardown, and logs viewport-clamped gestures and raw offsets.
After the user explicitly offered the MatePad, the final gate ran there using
the signed isolated ARM app: one combined link/long-scroll test passed, including
1500 rows, 6 drags over 11.558 seconds, 1686 positive scroll callbacks and 1952.37 vp
maximum offset. Controller/document loads remained 1/1 throughout; Close completed
in 1.602 seconds including test-driver work. Screenshots contain synthetic content
only and were inspected. The isolated app was removed; the emulator stayed stopped.

Development 0.1.18 (100018) was installed in place on Pura X and MatePad, without
launching production. Versions and matching artifact hashes were verified; saved
accounts are retained. See release-0.1.18.md and the validation JSON. The physical
thermal issue remains unconfirmed; no supported app-wide CPU quota was found.
Previously cached bodies/attachment labels remain preserved until the next body
fetch. Three rounds are complete. No additional review is scheduled or started.
