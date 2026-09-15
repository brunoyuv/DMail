# 1.0.1 — Archive, Trash and empty messages

Archive now works when an IMAP server supports UID MOVE but has no Archive
folder yet. The first explicit Archive action creates a server folder using the
personal namespace, or an unambiguous Inbox/root hierarchy when NAMESPACE is
unavailable. Existing Archive and Gmail All Mail destinations are reused.
Folder discovery and mailbox refresh never create folders.

The original Swift client checks the source UID, UIDVALIDITY and writable
selection before CREATE. It confirms the exact selectable destination with LIST
and rechecks the source before MOVE. A server refusal or unconfirmed creation
never moves the message. Ambiguous destinations remain unavailable. CREATE and
MOVE are bounded and uncertain operations are never replayed automatically.

A confirmed destination is saved in the same cache transaction as the moved
message. Bodies, pictures, attachment origins and retention timestamps survive
Archive and Undo. A late folder-list response cannot overwrite a newer confirmed
Archive destination. The current account's mailbox list updates from the cache,
without another server request. Existing accounts get one folder-metadata
upgrade to enable the new behavior; there is no bulk message download.

Attachment-only messages are also covered. A standalone image or an image-only
multipart message carrying Content-ID is treated as an on-demand attachment,
not assembled as a text/HTML body. This avoids a failed message open and an
unnecessary image download. PDF-only messages and empty-text messages with
attachments retain their existing behavior. Cached attachment metadata opens
offline without repeated downloads. Declared text/HTML that fails to download
is still reported as incomplete; attachments do not mask decoding errors.

Version 1.0.1 uses version code 1000001. The tablet split view, 320 vp account
menu, HTML rendering and the 0.1.28 performance fixes are unchanged.

The final 1.0.1 also includes a saved per-account Inbox swipe choice between
Archive and Delete. Delete verifies one existing Trash folder and moves with
the original Swift UID MOVE. Stale cached folder roles/permissions cannot
silently disable the explicit action. Undo retains the existing identity checks;
server refusals are reported and uncertain mutations are never replayed.

Empty composed and received text/HTML bodies remain valid, including mail with
attachments. A MatePad reproduction found that the native encoder returned no
byte array for an empty string. The file store now saves and reopens verified
zero-byte files explicitly, preserving owner, file-identity and retention checks.
Sent normalization and attachment-only downloaded indicators are included.
Genuine missing/failed text remains incomplete.

Validation passed: 755 JavaScript tests, 32 Python tests, 134 Swift protocol
and account tests, and 115 MIME/body tests. Two isolated MatePad native storage
tests passed after reproducing the empty-body failure. ARM and x86 native cores
and HAPs built successfully. The corrected signed development package was
installed in place on Pura X and MatePad with app/account-storage identities
preserved and no production launch. The signed input hash and installer success
were verified; the OS denied reading the installed HAP for its device-side hash.
No real mail was accessed. The emulator stayed stopped.

The finalized local history keeps exactly the original 1.0.0 and consolidated
1.0.1 commits. Pre-consolidation history, the working source changes and exact
1.0.0 snapshot are backed up under ignored `.tools/history-cleanup-101/`.
The separately signed AppGallery APP uses `some.DMail.hamorny`, version 1.0.1 /
1000001, and the existing release signing identity. Package hashes, source
revision and signature verification belong in its companion manifest in `dist/`.

See the [original validation record](../port/mail-corpus/release-1.0.1-validation.json),
[follow-up details](attachment-delete-follow-up.md),
[corrected installation record](../port/mail-corpus/empty-trash-installation.json)
and [release packaging instructions](release-packages.md).
