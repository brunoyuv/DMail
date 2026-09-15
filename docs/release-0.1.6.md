# 0.1.6 — message actions and composition preferences

Read/Unread and Star/Unstar remain tappable after repeated changes. Their visible
rectangles now match their touch regions and measured message-row height. A tap
closes the native swipe panel before replacing the row, dispatches once, and
retains its original account if navigation changes during the animation. Native
button enabled state observes operation acknowledgements explicitly. Archive
uses the same close handling. Taps on swipe actions cannot open the reader.

The message-list title reacts to the selected folder, so server Sent displays
Sent. Tablet split navigation and the existing visual design are retained.

After Load pictures grants permission for a message, Refresh pictures retries
its remote images. Ordinary reopen remains cache-first and offline-capable.
An explicit refresh coalesces duplicate requests and keeps the existing cached
image if a replacement fails; permission is not requested again. Existing
seven-day message/picture retention is unchanged.

Compose suggests recipients from previously accepted submissions for that
account. It also imports recipients from already downloaded, identified Sent
mail without contacting a server. The encrypted, account-local history is
bounded to 500 addresses, deduplicated and independent of message retention.
To, Cc and Bcc suggestions replace the current address token only.

Mailboxes → Settings offers per-account sender name and multiline signature.
Changes save automatically. New messages, replies and forwards snapshot those
preferences; reopening a draft preserves its contents without appending a
second signature. Sender names are safely encoded in the original Swift SMTP
MIME header and cached Sent copy; the envelope address and server login stay
separate. No additional server request is needed to edit these preferences.

## Validation

- All 154 host tests passed, including 14 component race/swipe regressions,
  21 picture cache/consent tests, eight recipient-history tests and five
  composition-preference tests.
- Three focused Swift sender-identity tests passed, covering Unicode headers,
  MIME/envelope consistency and rejection of header injection.
- ARM and x86 production builds passed. The signed ARM artifact contains the
  current UI/bridge source and native libraries.
- The bounded native swipe test passed Read/Unread and Star/Unstar center/edge
  taps, a held-acknowledgement double tap, exactly four fake flag changes and
  preserved cached bodies, without opening the reader. System boundary view
  was left unchanged.
- Native sender-identity preflight and the synthetic composition UI test passed.
  Sent title, Settings autosave, recipient selection and draft reopen were
  checked with zero mail service calls and no send. The Sent screenshot was
  visually reviewed; the composer capture occurred during navigation animation
  and is not final layout evidence.
- Pura X VDE-AL00 and MatePad MRO-W00 were upgraded in place to 0.1.6 (100006).
  Both bundle versions and artifact hashes match the verified signed build.
- The isolated fixture was removed, the emulator stopped and its original screen
  profile restored. The earlier setup timeout and its correction are recorded in
  the [validation record](../port/mail-corpus/release-0.1.6-validation.json).

Automated mail checks use synthetic fixtures only. Production accounts remain
unopened, and installs are in-place upgrades preserving saved accounts.
