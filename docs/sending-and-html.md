# Sending and HTML mail

The first SMTP sender ports Thunderbird's original 11-file `Core/Sources/SMTP`
module. `port/swift-smtp/upstream-files.json` pins its source hashes and
`harmonyos.patch` records the adaptations. Server, ConnectionSecurity and ByteHandler remain unchanged. The transport uses SwiftNIO/NIOSSL on HarmonyOS;
ArkTS supplies settings and presentation, not an independent SMTP engine.

The native client requires SSL/TLS or mandatory STARTTLS, validates system and
app trust/pins, repeats EHLO after the verified handshake and negotiates LOGIN or
PLAIN authentication. It sends one transaction to all To/Cc/Bcc recipients,
rejects the entire submission before DATA when a recipient fails, omits Bcc from
headers, folds encoded subjects, uses UTF-8 MIME/base64 bodies and dot-stuffs DATA.
Connections have a 10-second connect deadline and a 30-second transaction deadline.
A 250 response to DATA means acceptance even if QUIT disconnects. A disconnect or
timeout after DATA but before acknowledgement means delivery is unconfirmed;
there is no automatic retry. Concurrent submissions of the same message ID are
blocked. Passwords and message contents are not logged.

Compose opens from the inbox's pencil button, with Cancel and Send at the top,
compact address/subject rows, expandable Cc/Bcc and an unboxed body editor.
The More (⋯) menu opens a separate Outgoing server sheet for the provider's SMTP
hostname, port, security, login and password. Identity comes
from the account's separately saved email address. Settings use Asset Store with
DEVICE_UNLOCKED accessibility and no synchronization. Database schema 4 adds an
encrypted, account-scoped draft record without replacing saved accounts or cache.
Edits save locally. The app persists `sending` before contacting SMTP; interrupted
sends reopen as unconfirmed and require an explicit manual retry decision.
Successful submissions return to the inbox with a Sent toast. The next Compose
starts a fresh message; the previous local sent record is replaced when that
draft is saved. Cancel offers Save draft or Discard. Only one local composition
is retained per account in this first version.

Current limits: plain-text composition, explicit ASCII mailbox addresses without
display names, password/app-password authentication, no attachments and no IMAP
Sent-folder upload. Server acceptance does not guarantee final delivery. Browser-based OAuth is under investigation alongside the next server-settings
port; provider-specific integration requires real provider registration details.

HTML reading uses the original Swift MIME body decoder for IMAP and the original
JMAP body-value retrieval. The shared DTO and encrypted cache retain both HTML and
plain text, preserving compatibility with older cached records. The reader opens
HTML automatically where available, without a plain-text toggle. Text-only mail displays its text. HTML is capped at 2,000,000
characters for IMAP; JMAP keeps its 256-KiB body-value cap and truncation flags.

A native ArkWeb view renders a local document with a restrictive Content Security
Policy. JavaScript, file access, storage, geolocation, frames, forms and plugins
are blocked. Document links cannot navigate or invoke other apps. Embedded CID
images are inlined by the original IMAP Account body code. Remote pictures are
hidden until Load pictures is selected for the displayed message; CSP continues
to restrict network requests to images. Link opening remains unimplemented.
The message headers and HTML share one Scroll, using native Web FIT_CONTENT
layout with synchronous rendering for long newsletters. These restrictions do not
claim to sanitize arbitrary markup; they use the Web component's security controls
and a policy prepended before the message.

The September 2026 [UI refinement plan and results](ui-refresh-plan.md) records
the current layout: aligned compact inbox rows, expandable recipient details,
a centered reader/composer column and responsive HTML tables and images.
Remote-picture permission is scoped to message identity, even when another
message has identical HTML. The persistent-renderer consent regression is part
of the synthetic mail UI flow.

`HDC_TARGET=DEVICE scripts/test-device-mail-features` installs a separately signed
fixture app, tests only synthetic local SMTP/IMAP servers, checks emitted messages,
reads HTML and submits through the production composer. It removes the fixture
app and forwarding afterward. The Swift core in that app must match the signed
production HAP byte for byte. The emulator is never started by this test.

For routine UI iteration, prepare x86 builds with `scripts/prepare-native-app` and
`scripts/build-imap-test-app` while the emulator is stopped, then run
`scripts/test-emulator-mail-ui`. It checks the HTML reader, restored draft,
SMTP settings sheet, synthetic send and next composition, saves screenshots,
and automatically shuts down the emulator. It does not run the full protocol
or Swift runtime regression suites.

The earlier send/HTML emulator flow passed on 13 September 2026; its native process exited
and the emulator was confirmed stopped. See the [evidence record](../port/swift-smtp/emulator-ui-result.json)
and settled [composer](screenshots/emulator-compose.png) and [HTML reader](screenshots/emulator-html.png) screenshots.

## Connected replies

The reader has a native circular Reply button, with a standard edge margin and
no Refresh toolbar action. Composer Cancel and Send use native capsule button
styles, with Send emphasized. The Reply menu prepares
Reply or Reply All in the same SMTP composer.
It prefers Reply-To over From, removes the account's own address and duplicate
recipients, includes original To/Cc recipients for Reply All, and never copies Bcc.
Replying to one's own message uses its other recipients. An existing unfinished
or uncertain draft is preserved: the user can resume it or cancel the reply.

The original Swift SMTP Email/RequestEncoder now carry In-Reply-To and folded
References headers following [RFC 5322 section 3.6.4](https://www.rfc-editor.org/rfc/rfc5322#section-3.6.4).
The IMAP Message adaptation retains the bounded top-level References header before
MIME body decoding. JMAP provides the same metadata through its original Email
model. Old cached messages remain readable. Invalid message IDs cannot become
arbitrary headers. Quoted text and long reference chains are bounded; HTML-only
messages without decoded text produce an empty reply body rather than raw markup.

The server's Sent mailbox is still not populated automatically. Sending a reply
does not yet mark the original message Answered. These are separate remaining
workflows, not part of the reply-preparation confirmation.

Reply validation is recorded separately in [reply-result.json](../port/swift-smtp/reply-result.json):
59 host model tests, four original Swift reply-header tests, and the emulator UI
flow with two synthetic submissions. The flow checks draft preservation, Reply
All recipients, thread headers and blocked remote HTML requests. Current ARM
package verification checks source/library parity; it does not establish live
SMTP delivery or execution of the new reply path on a physical device.

The signed update installed successfully on the reconnected Pura X on 13 September
2026, preserving the existing installation. Final emulator captures show the
[reader toolbar](screenshots/reader-actions.png), [composer buttons](screenshots/composer-buttons.png)
and [Reply All composition](screenshots/reply.png). The emulator was stopped
immediately after its successful test.

## Forwarding and toolbar consistency

Reply, Reply All and Forward share the reader's native menu. Forward creates an
empty-recipient draft with an `Fwd:` subject and visible original From/Date/Subject/
To/Cc information. It starts a new message without In-Reply-To or References and
never copies Bcc. Existing unfinished drafts are preserved.

Text-only mail forwards as editable text. HTML forwards retain the original HTML
in a blocked-network preview below the introduction editor, then use Thunderbird's
original MIME Part/Body and SMTP encoder to send an HTML body. The introduction
is HTML-escaped. Oversized bodies are rejected explicitly instead of being silently
cut. Attachments are not included; the composer shows a warning if the source has
attachments. It also warns about truncated or incorrectly decoded source content.

The main inbox toolbar contains only Compose and Mailboxes, with 44-vp circular
controls, 12-vp spacing and a 16-vp edge margin. Message lists refresh through the
native pull-down gesture only. Reader Reply and composer More use the same neutral
circular style. Cancel is a normal capsule and Send is emphasized, both 44-vp high.

Unread inbox rows use a 3-vp blue vertical bar at the screen edge. Sender,
subject, preview and dividers share a 20-vp inset with the account header;
the previous unread-dot column no longer pushes message text to the right.
See the [updated inbox](screenshots/inbox-unread-bar.png).

The [HTML/Forward validation record](../port/swift-smtp/html-forward-result.json)
records 62 host model tests, 61 MIME/account-body tests, six Swift reply/composition
tests and the emulator UI flow with three synthetic submissions. The flow checks
explicit remote-picture loading, unified scrolling and HTML forwarding. The
emulator exited after testing. The signed build was installed over Wi-Fi on Pura X
on 13 September 2026; the inbox alignment was visually checked. The specific
reported blank newsletter and its live-provider images still need a device recheck.
