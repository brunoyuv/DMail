# 0.1.4 — preview layout, dark replies and server Sent

The installed inbox, reader and composer follow the existing layout preview.
Tablet split navigation is retained. HTML follows application light/dark mode
without reloading the message, resetting quote expansion or losing pictures.

The Swift IMAP and SMTP paths share one Sent-folder resolver. A unique selectable
declared Sent folder wins; otherwise one existing conventional Sent folder is
accepted, including an INBOX child. Ambiguous or conflicting folders are never
guessed or created. Gmail returns its actual Sent ID when metadata succeeds and
continues using server auto-save without duplicate APPEND.

Older local Sent views merge into the discovered server Sent view transactionally.
Downloaded bodies, pending flags, pagination and retention timestamps survive.
A matching server Message-ID reuses the saved body. If no server destination is
known, the fallback is clearly labeled “Sent on this device.” Historical copies
that were never saved remotely remain available locally; migration does not
silently upload them, retry SMTP or retry an uncertain APPEND.

Only stale legacy metadata triggers one background folder lookup per account
per session; cached message bodies remain available immediately. Completion is
applied to the original account even if the user navigates elsewhere.

## Validation

- 120 host tests and seven focused Swift tests passed.
- Signed ARM and x86 production builds passed; shipping source/native library
  parity was verified.
- Six native Sent-copy tests passed on the MatePad with eight synthetic SMTP
  submissions, ten Sent metadata connections and zero fixture violations.
- Dark reader/reply and forward checks passed: native palette, authored white
  HTML, nested quote expansion through live theme changes, and original image
  colors. All six screenshot pixel gates passed and screenshots were inspected.
- Inbox, HTML reader and composer passed in both MatePad orientations. The
  44 vp controls, same-row title, simultaneous split panes, normal unread-row
  heights and visible 3 vp unread marker were verified. The fixture made zero
  service calls. Final screenshots were inspected.
- The emulator stayed stopped. The isolated test app was removed after each run.
- MatePad was upgraded in place to 0.1.4 (100004); bundle metadata was verified.
  Accounts were preserved and production was not launched. Pura X was not
  connected, so its earlier 0.1.3 installation remains unchanged.

The first HTML fixture's native assertions passed, but its screenshot gate
correctly rejected black native backgrounds. Diagnostics identified unresolved
numeric resources in the extra test feature module. The visual fixture now runs
in the isolated application's main ability, using the same source and resource
path as production. No production workaround or relaxed pixel threshold was used.

Automatic approval review rejected reading the MatePad's current UI layout due
to the existing private-mail boundary. No real mail was retrieved. Native
validation uses an isolated synthetic test application; production stays closed.

Synthetic screenshots: [tablet reader](screenshots/release-014-tablet-reader.png),
[tablet composer](screenshots/release-014-tablet-composer.png),
[dark quoted HTML](screenshots/release-014-dark-quotes.png).
Full [validation record](../port/mail-corpus/release-0.1.4-validation.json).
