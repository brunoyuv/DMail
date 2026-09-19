# Read state when opening cached messages

The user reported that expanding a combined reply or reopening a message
manually marked unread could leave it unread. Foreground IMAP page/body reads
use EXAMINE. Their cached `maySetSeen` and `maySetKeywords` values can therefore
be false without establishing that the account cannot modify the message.

ConnectedMail's automatic read-on-open gate previously trusted those cached
permissions, while its explicit swipe action already deferred permission checks
to the native mutation path. The reader now shares the row-action gate, retaining
its own busy guard. Original Swift SELECT still verifies mailbox permissions and
UIDVALIDITY before STORE and requires an explicit target FLAGS acknowledgement.
JMAP still requires permission in every mailbox. Pending operations, uncertain
cache state, local copies and read-only accounts remain guarded.

Only a successfully opened message is marked read. Expanding a reply operates on
that reply's protocol ID; folded unread messages are not bulk-marked. Flag
acknowledgements continue to update the original account's cache and reader
metadata without replacing the mounted body.

Validation on 2026-09-19:

- Both new behavioral regressions failed before the gate change and passed
  afterward: manual unread followed by reopen, and expansion of a combined reply.
- Guard coverage and the full host suite passed: 820 JavaScript and 43 Python
  tests, including 33 ConnectedMail operation tests.
- The SDK 26 ARM64 HAP compiled and packaged successfully with existing native
  libraries. Staged main sources exactly match the workspace; the device-package
  verification script passed.
- Version remains 1.0.4 (1000004). At the user’s subsequent request, the signed
  update was installed in place on Pura X. The installer confirmed success,
  app/storage identities were preserved, and the production process was absent
  afterward. No real-mail access, commit, push or public release was performed.

Read-on-open behavior on the device remains for the user to verify. The signed
input hash and installation receipt are recorded in
[read-on-open-installation.json](read-on-open-installation.json); installed HAP
bytes were not read. Other in-progress workspace changes were preserved and
are included in this build. MatePad was unchanged.
