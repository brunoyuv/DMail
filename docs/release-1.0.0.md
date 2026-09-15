# 1.0.0 — attachments and Archive

The composer has an Attach files row below Subject, with the file name, size and
Remove action for each attachment. The system file picker grants access to the
selected files. Up to ten files, totaling 10 MiB, can be added to a message.
Private files survive draft reopen; the encrypted database stores only metadata
and owned file references. Explicit discard cleans up the matching draft files.
The original Swift MIME encoder supplies multipart boundaries, transfer encoding
and Unicode attachment names, and the original SMTP client sends the result.
The same complete MIME message is used for the server Sent copy where required.
A send with an uncertain outcome is never retried automatically.

Received attachments have Open and Save controls in the reader. Downloads now
use persistent private storage and retain existing Unicode filenames and the
seven-day cache policy. Fresh files in the earlier temporary cache migrate without
redownloading. The existing received-attachment limit remains 4 MiB of encoded
part data. Sent attachments open from their owned local files while available.
Forwarding does not automatically include the original attachments; they can be
saved and attached through the picker.

Archive is available in Inbox row swipes for supported writable accounts. IMAP
uses the server's Archive or All Mail special-use folder, or an unambiguous existing
Archive/Archives folder, and Thunderbird's original UID MOVE command. It neither
creates a second archive folder nor uses mailbox-wide EXPUNGE. Servers without
MOVE or an unambiguous destination leave Archive unavailable. Existing saved
accounts receive one mailbox-role metadata upgrade so the action becomes
available without removing the account.

The Inbox updates optimistically while the operation runs. A confirmed UID
mapping preserves the body file, picture identity and attachment cache aliases;
Undo moves the message back using its new UID. If MOVE succeeds without a usable
mapping, an explicit local archived copy remains readable offline and Undo is
unavailable. An uncertain server result is reported without automatic replay.
Offline archives are not queued for later submission.

The tablet account dropdown is capped at 320 vp instead of expanding across
the window. Long addresses remain on one line with an ellipsis. The tablet split
view and the 0.1.28 HTML fixes are preserved. HTML rendering,
image scanning, automatic-work pacing and background connection behavior are
unchanged. All automated mail tests use synthetic data; production accounts and
mail contents are not accessed by tools.

Validation passed: 716 JavaScript tests, 32 Python tests and 119 Swift protocol
and account tests. ARM and x86 native cores and HAPs compiled. The isolated phone
and tablet UI tests verified received attachment cards, Unicode composer rows,
removal persisted after draft reopening, and the tablet split reader. The tablet
account dropdown also passed its native width check. Screenshots were inspected;
the emulator stopped after each bounded run. The verified signed package was
installed in place on Pura X and MatePad with accounts preserved and without
launching the production app.

Build, test and installation evidence is recorded in
[the validation record](../port/mail-corpus/release-1.0.0-validation.json).
