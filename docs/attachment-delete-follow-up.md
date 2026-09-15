# Attachment-only mail and the Delete setting

This follow-up retains version 1.0.1 (1000001). After the user requested
installation, the first signed package was installed in place on Pura X and
MatePad. The subsequent device-reported failures and corrected update are
recorded below. The user subsequently requested consolidating the complete fixes into the
1.0.1 commit and preparing a signed APP. This authorizes local history
consolidation and packaging; no remote push or store upload is included.

## Empty messages with attachments

The SMTP Sent path decodes its generated editable MIME body before caching it.
The original account-body adapter rejected a zero-byte text body, so a successful
empty composition could be saved with both text and HTML set to null. Separately,
the reader described every such null body as a decoding error, and the cached
header summary did not mark attachment-only metadata as downloaded.

The explicit `port/swift-accountbody/body-adapter.patch` now accepts an existing
zero-byte text/HTML MIME body as empty. A missing MIME body and an empty multipart
container still fail. Accepted local Sent records retain an explicit empty text
representation. Existing cached attachment-only messages need no migration or
network request: their original successful download timestamp and attachment
metadata now supply the downloaded indicator, and the reader displays “No message
text.” instead of a false decoding error. English and Simplified Chinese are
included.

An advertised nonempty IMAP text part that returns no bytes remains incomplete.
Attachments do not clear genuine text decoding or partial-fetch errors. File
attachments remain on demand, with the existing size limits and retention rules.

## Account setting

In Settings, select an IMAP account and set **Inbox swipe action** to **Archive**
or **Delete**. Archive remains the default. The saved choice is independent of
sender/signature settings. It survives reopening and is removed with the account.
The row action changes its label, icon and color after a successful settings write.
An action already pressed retains its original account and choice across navigation.

Delete moves one Inbox message to one existing Trash folder using the original
Swift UID MOVE encoder. A declared `\Trash` folder takes precedence; otherwise
one unambiguous root/Inbox conventional Trash, Deleted Items or Deleted Messages
folder is accepted. Missing, ambiguous, nonselectable or conflicting-role folders
are refused. Delete requires server MOVE support. It never creates a folder,
uses mailbox-wide EXPUNGE, or falls back automatically from a failed Archive.

Source UID, UIDVALIDITY and writable selection are checked before the move.
Confirmed UID mappings enable Undo back to Inbox. An uncertain move is not
replayed; a confirmed move without a UID mapping retains an explicit offline
copy and cannot offer Undo. Cached bodies, pictures, attachment origins and
original retention timestamps follow the existing transaction path. Confirmed
Trash metadata preserves the separate Archive role and creation hint; stale
folder responses cannot overwrite it. Mailbox role revision 5 gives saved
accounts read-only discovery of the new Trash role.

## Validation

- 751 JavaScript tests and 32 Python tests passed.
- 115 Swift MIME/body tests passed, including zero-byte composition bodies.
- 134 Swift protocol/account tests passed against synthetic loopback TLS peers.
  Delete coverage includes Undo, missing/ambiguous Trash, read-only source,
  changed UIDVALIDITY, missing/wrong UID, rejection, dropped replies and timeouts.
  The attachment fixture distinguishes zero-byte text from a missing advertised
  nonempty text part.
- ARM and x86 Swift native cores and production HAP builds passed using the
  configured SDK 26 tools; native sysroot and target/minimum remain API 22.
- UI layout on a running device has not been verified in this follow-up.
  No real mail, production launch or emulator run occurred. The subsequent
  user-authorized installations are recorded below.

Local build/test output is under ignored `.tools/attachment-delete-*.log`.

## Installation

Installed in place on Pura X (VDE-AL00) and MatePad (MRO-W00), retaining version
1.0.1 / 1000001. Both installers confirmed success. Bundle ID, application ID,
UID, first-install time and account-storage identities are unchanged. Production
was not launched and no mailbox was accessed.

The verified signed input package SHA-256 is
`868ce903141069034961aa3164c3dc8b0e70d8809298b1dafa36e26678e107bb`.
The OS denied direct reading of the installed HAP on both devices, so a
device-side package hash was not obtained. No access restriction was bypassed.
See the [installation record](../port/mail-corpus/attachment-delete-installation.json).
Private device identifiers and raw installation metadata remain under ignored
`.tools/attachment-delete-install/`.

## Correction after device feedback

The user reported that Delete still did nothing on their private server with a
folder named Trash, and empty messages still failed to download. The first host
checks did not reproduce the native empty-string behavior.

A bounded test in the isolated MatePad app reproduced two failures: native
`TextEncoder.encodeInto('')` returned undefined, and `MailContentFiles.write`
failed while saving an empty body. The store now represents empty content with
an explicit zero-byte array and returns an empty string for a verified zero-byte
file. Account ownership, path checks, atomic file publication, retention and file
identity checks still run. The corrected native tests passed for empty text,
empty HTML and normal Unicode content after reopening the file store. The test
app was stopped and removed; production mail was never accessed.

The Delete button also incorrectly treated cached Trash roles and move
permissions as authoritative. An explicit Inbox Delete now invokes original
Swift discovery even if that cached destination is missing or stale. Until the
server confirms the destination, the message remains pending in Inbox. The
verified receipt determines its final folder and UID. Missing/unusable Trash now
reports a specific error, retaining the original membership without retrying.
Server MOVE support and all native source/destination checks remain required.
The private server's capabilities and actual mail were not inspected.

### Correction validation

- 755 JavaScript tests pass: the full suite passed with 752 tests, then the two
  changed suites passed again with three additional regressions (20 move tests
  and 9 content-file tests). All 32 Python tests passed.
- Two isolated MatePad native storage tests passed after the reproduced failure.
- ARM and x86 production HAPs rebuilt with SDK 26. The original Swift libraries
  are unchanged from the previously validated builds (115 MIME/body and 134
  protocol/account tests).
- The emulator remained stopped. No production launch or real-mail access occurred.

Correction logs are under ignored `.tools/empty-trash-*.log` and
`.tools/empty-trash-native/`, including the failing pre-fix native result.

### Corrected installation

The corrected package is installed in place on both Pura X and MatePad,
retaining 1.0.1 / 1000001 and the original app/account-storage identities.
Both installers confirmed success. Production remained unopened.
The signed input package SHA-256 is
`5878b1edd6256d992ee88cc9b8da8a2d4d650ae63da2bcbb1265d4c9d8296517`.
As before, the OS denies direct access to the installed HAP; its device-side
hash is unverified. See the [corrected installation record](../port/mail-corpus/empty-trash-installation.json).
