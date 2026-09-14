# D-Mail

D-Mail is an independent HarmonyOS mail client using Thunderbird's original
Swift core. Preserve upstream attribution, MPL notices, source hashes and explicit
port patches. Do not replace the Swift protocol clients with an independent
ArkTS implementation. App-facing branding uses D-Mail. Keep the legacy bundle ID,
database/Asset identities and native ABI names for signing, saved-account and
upgrade compatibility. See docs/publishing.md and docs/upstream-reuse.md.

## Current package and publication scope

Google browser sign-in and reconnect are disabled by default using the build
constant RegisteredMailOAuth.googleBrowserSignInEnabled. Show Gmail app-password
guidance in English and Simplified Chinese. Preserve saved OAuth validation,
refresh and Microsoft sign-in. Experimental Google login needs explicit build
opt-in; do not silently enable it during packaging.

Publication preparation does not authorize a GitHub push or device installation.
Keep signing, OAuth secrets, toolchains, logs and device serials under ignored
.tools/. Public historical records redact serials; the local pre-publication
snapshot is at .tools/pre-d-mail-publication/. Physical MatePad runners require
DMAIL_AUTHORIZED_MATEPAD_SERIAL in addition to a verified HDC_TARGET.

## Latest installed baseline

Release 0.1.11 (100011) was installed and metadata/hash-verified on Pura X and
MatePad. Its 289 host tests, six focused Swift tests, 4.183-second native IMAP
count gate and 12.524-second persisted badge/notification-lock gate passed.
Upgrades preserved accounts; production was left closed. See
[release evidence](docs/release-0.1.11.md) and its JSON under port/mail-corpus/.
These records predate the D-Mail branding and Gmail-default changes.

## Privacy and test boundaries

Use synthetic fixtures for all automated mail tests. Real-account retries,
provider sign-in and mailbox consent are user-operated. Do not read real mail,
open production, capture physical mail screens, consent or send on the user's
behalf. Earlier error-only screenshot permissions were limited to those specific
screens and do not authorize current access. Automatic approval review previously
rejected physical UI capture that could expose mail; do not retry through another
route. Preserve saved accounts on any authorized in-place install and leave the
production app closed.

The emulator can freeze the desktop. Keep it stopped while coding/building.
Prepare device tests first, then run through scripts/with-test-emulator for
bounded execution and cleanup on success, failure and interruption. Stop it
immediately after tests and separately verify native-process absence. Prefer
emulator UI checks over physical-device UI checks. Do not leave it running idle.

## Builds

Use CLI 26.0.0.821, Hvigor 6.26.4 and SDK 26.0.0.105 through
scripts/harmony-build-env and the separate .tools/hvigor-home-26 cache. Compile
SDK is 26; target/minimum and the Swift native sysroot remain API 22. SDK 26 does
not grant additional permissions or relax background scheduling. Preserve ignored
signing under .tools/device-app/ when staging/rebuilding; merge signing into the
current profile rather than preserving obsolete compiler settings.

## Accounts, OAuth and operations

Open the last visited account from encrypted cache before requesting the server.
Keep account switching and browsing responsive during background operations.
Keep email identity separate from server login. Reconnect must verify the saved
login, replace tokens under the same account/key and preserve cache, drafts,
SMTP settings and preferences. Different identities, cancellation and an older
in-flight refresh cannot replace or overwrite the saved account.

Concurrent OAuth refresh waits at most 20 seconds for the lease owner and reuses
its saved token. Persist token rotation before use. Gmail bearer credentials are
allowed only at the exact approved SMTP587/SMTPS465 endpoints and bound login.
Disable/remove revokes background credentials. Never copy SMTP credentials into
background entries. Error messages retain only safe stages and allowlisted
protocol codes, never provider responses, callback URLs, tokens or account data.

Never automatically retry uncertain SMTP delivery or APPEND. Keep confirmed sent
bodies locally and report Sent-copy failure separately from delivery. Use the
server's declared Sent folder, or one unambiguous existing conventional folder;
never create or guess ambiguous folders. Preserve downloaded bodies, pending
flags, retention and pagination when reconciling old local Sent copies.

Guard asynchronous UI/cache writes with account ownership, navigation generation
and operation revision. Apply pending local flag/move overlays. Dirty flags must
not hide bodies or trigger repeated body downloads. Persist acknowledgements to
the original account even after navigation. Close native row swipes before
replacing flag-keyed rows, dispatch once, and flush operations before teardown.
IMAP flag changes verify UIDVALIDITY and an explicit target FLAGS response.

## Storage, unread counts and notifications

Keep seven-day retention measured from body download, not message age. Cached
bodies and pictures survive failed refresh; consent is per message/account.
Opening fresh downloaded content is cache-first. Explicit Refresh pictures
coalesces requests and preserves old bytes on failure. Missing-body retry retains
the actual safe error, fetches no extra mailbox metadata, and displays the body
before optional permissions. A changed UID epoch returns to the folder.

Native RDB pooled readers may miss uncommitted writes. Count guards read the
revision before incrementing; notification and OAuth leases read ownership after
committing atomic conditional writes. Preserve separate-reader WAL regression
tests; never rely on single-connection mock read-after-write assumptions.

The OS badge sums last-checked full Inbox unread totals for alert-enabled
accounts. Unknown enabled-account totals clear the badge until checked. Preserve
pending projections and revision guards. Keep in-app unread markers for all
accounts. Muted accounts suppress foreground banners. Optional same-session IMAP
STATUS for MESSAGES/UNSEEN has a two-second deadline; failure preserves arrivals.

Foreground Inbox arrival hints reuse Swift IDLE independently of notification
permission/opt-in. Coalesce per-account revisions and quietly refresh headers on
arrival/resume without body, Sent or mailbox-list requests. Pause queued refreshes
in background, composer, scroll and swipe interactions. Preserve bodies, dirty
flags and an overlapping paginated tail. Restore scroll by row ID/pixel offset,
never after user scrolling. ForEach lacks maintainVisibleContentPosition.

Connect directly to the user's existing server. No required private relay,
hosted watcher or Huawei Push Kit backend. Public WorkScheduler intervals remain
2/4/6/12 hours; minute-level background checking is unresolved. A restricted ACL
route exists but email eligibility is unverified; no application was submitted.
See docs/background-checking.md. Debug entitlements do not prove release access.

Alerts default off and first enable establishes a silent baseline. Foreground
fallback intervals are 5/15/30/60 minutes. Notification content stays generic;
taps preserve a composer before navigating to the original account. Background
entries allow access after first unlock; foreground credentials remain
DEVICE_UNLOCKED. Background database opens skip normal pruning/migrations.
Use durable leases, revisions and an alert outbox. Retain busy/failed/backed-off
IDLE events; quiet snapshots are local bridge reads, not server requests. Stop
watches in background. Poll at most 50 UID/FLAGS records, never headers or bodies.

## Interface and composition

Follow docs/ui-layout.html and native HarmonyOS conventions. Keep tablet split
navigation, title/action alignment, colors, typography and gutters. A saved
account opens to its real inbox; setup is under Mailboxes → Accounts. No sample
mail in production launch. Use a measured vertical unread bar with no dot column;
never percent-height sizing in the intrinsic Stack. Align row text/dividers with
the account header. Keep mailboxId reactive and swipe state tied to revisions.

Hide empty search initially; reveal when returning to the top. Keep nonempty
search visible. Use native pull-to-refresh. Inbox toolbar has only Compose and
Mailboxes. Reader has a circular Reply menu for Reply / Reply All / Forward;
read/star/archive actions belong in row swipes, not its toolbar. Opening a message
marks it read after permissions resolve, without duplicate pending operations.

Show HTML automatically, with headers/body scrolling together and inline CID
images automatic. Remote images require Load pictures consent. Use native ArkWeb
forced dark adaptation for authored HTML; preserve quote colors, expansion and
pictures across theme changes. Group conversations by Message-ID/reply headers
or server thread ID, never subject alone. Collapse older cards and quoted text.

Composer uses Cancel/Send native capsules, compact address/subject rows,
expandable Cc/Bcc and an unboxed editor; SMTP settings are separate. Sending
success returns to inbox and later Compose starts fresh. Sender name/signature
preferences autosave per account and are snapshotted once for new/reply/forward;
draft reopen never appends another signature. Retain up to 500 encrypted,
account-local recipient-history entries independently of mail expiry.

Language settings offer system, English and Simplified Chinese. Validate compact
phone, cover and both tablet orientations with synthetic/public fixtures. Only
Pura X cover normally hides the status bar (980 × 980 px, density 3). Resource
colors require native visual fixtures in the isolated app's main ability, not
its extra test module. Make fixture-directory creation idempotent, stop isolated
processes between sequential aa runs, and let navigation animations settle before
using screenshots as layout evidence.
