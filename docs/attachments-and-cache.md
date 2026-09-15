# Attachments and seven-day mail cache

The IMAP reader now shows attachment names from BODYSTRUCTURE. Tapping a file
fetches that selected part through Thunderbird's Swift IMAP client and decodes
it with the ported MIME/EmailAttachment code. The download validates the selected
UID and mailbox UIDVALIDITY before returning data. Reading a message does not
fetch its PDF attachment. Servers omitting BODYSTRUCTURE retain the bounded
whole-message fallback and expose decoded attachments by stable index within
that immutable message.

The attachment row offers Open and Save. Open hands a sandbox file URI to a
HarmonyOS file handler with read permission. Save uses the system document
picker. PDF preview currently depends on a registered PDF application; native
PDF Kit preview is being evaluated. The emulator lacks a PDF handler and displays
a system “no available opening method” dialog. Its successful download test does
not establish PDF rendering.

Downloads currently have a 4 MiB encoded-part limit and a 4 MiB decoded-file
limit. Attachment rows label encoded sizes as download sizes. Larger files are
listed but cannot yet be downloaded. Multipart attachments and extended filename
parameters still need compatibility work. Forwarding attachments is not yet
supported.

Downloaded message bodies remain in the encrypted account database for seven
days, measured from download. Reopening a complete, fresh saved body avoids a
new IMAP connection. Inbox refreshes preserve that body timestamp. Old cached
messages that predate attachment metadata are fetched once to populate their
attachment list. Partial or failed bodies can retry instead of being held for
seven days. Opening an unread message still marks it read on the server.

Expired records and bodies are pruned when the account database opens; freshness
is also checked before using a body. Downloaded files live in the app's private
cache, expire after seven days, and are deleted when their account is removed.
The OS may reclaim cache files earlier. Files explicitly saved with the system
picker belong to the user and are not removed by cache cleanup.

## Evidence

- `scripts/test-imap-upstream --filter ReadableBodyTests`: seven host tests pass,
  including PDF part selection and attachment metadata.
- `scripts/test`: cache boundary, non-sliding expiry, attachment metadata upgrade,
  and incomplete-body retry checks pass alongside existing host tests.
- `scripts/test-emulator-corpus pura-main attachments`: native UI test passed
  on the HarmonyOS 6.0.2 API 22 emulator at 1320 × 2120. It verified the attachment
  row, zero new IMAP connections on repeated email open, exactly one explicit
  PDF download, and all 2,495,611 downloaded bytes using SHA-256. Cleanup verified
  closed fixture connections and stopped the emulator.
- The visual capture confirms that external PDF rendering is unavailable in
  this emulator image. Open and Save still need confirmation on the Pura X.
- The subsequent cache-upgrade guard is host-tested. The short-message top
  alignment change compiles but needs another visual check.

Fixture source and size profiles are recorded in `port/mail-corpus/manifest.json`
and `port/mail-corpus/screens.json`. Ignored per-run logs, screenshots and hashes
are saved under `.tools/mail-ui/pura-main-attachments/`.

Platform integration reference: [Huawei file-handler guide](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/file-processing-apps-startup).
