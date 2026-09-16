# D-Mail

D-Mail is an independent HarmonyOS mail client using Thunderbird's original
Swift core. Preserve upstream attribution, MPL notices, source hashes and explicit
port patches. Do not replace the Swift protocol clients with an independent
ArkTS implementation. App-facing branding uses D-Mail. Keep the legacy bundle ID,
database/Asset identities and native ABI names for signing, saved-account and
upgrade compatibility. See docs/publishing.md and docs/upstream-reuse.md.
Exception: the explicit `scripts/build-release --appgallery` variant uses the
owner's registered `some.DMail.hamorny` bundle ID from packaging/appgallery.json
only in generated staging. Preserve its exact case/spelling. It is a separate
app identity. Use the existing matching AppGallery release key/profile under
ignored .tools/signing/appgallery/; never use device debug signing for it.

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

## Version 1.0.2 Markdown and math release

The user requested a new local commit named 1.0.2 after the Fira Math update.
This supersedes the earlier two-commit limit: preserve 1.0.0 and 1.0.1 and add
1.0.2 (1000002), without rewriting them or pushing remotely. D uses Fira Math
throughout equations, with corrected local TeX fallback for missing glyphs.
C remains unchanged; sending remains original Markdown/TeX source only.
Preserve MIT, Apache-2.0 and OFL-1.1 component licenses and font source hashes.
The native reader permits bundled OTF/WOFF2 data fonts only in generated math
documents, within the existing 256 KiB per-font URL limit. Keep source/cache
separation and D's math6 cache revision. 1.0.2 is installed in place on Pura X;
app/storage identities are preserved, signed input hash and installer success
verified, and production was not launched. MatePad remains unchanged. All 779
JavaScript and 40 Python tests pass; device Fira visual rendering is not yet
verified. See docs/release-1.0.2.md and its validation record.

## Attachment-only and Delete setting follow-up

The local follow-up after 1.0.1 fixes empty composed MIME bodies, the false
null-body reader error, and attachment-only downloaded indicators, including
previously saved Sent records. Preserve actual partial/failed text errors.
Per-account IMAP Settings now offers Inbox swipe action: Archive (default) or
Delete. Delete uses original Swift UID MOVE to one existing verified Trash
folder; never create Trash, fall back from Archive automatically, replay an
uncertain move, or use mailbox-wide EXPUNGE. Preserve Undo, file/cache origins,
retention, account-bound action snapshots and separate Archive folder metadata.
Host tests and both native builds pass. The user subsequently requested
installation: the same signed package is installed in place on Pura X and
MatePad, retaining 1.0.1 (1000001), with app/storage identities preserved and no
production launch. Signed input hash and installer success are verified; the OS
denies direct reading of the installed HAP. The user subsequently authorized
consolidating all fixes into the 1.0.1 commit and preparing a signed APP. Preserve
exactly 1.0.0 and 1.0.1 on main, with 1.0.0 unchanged and a recovery bundle plus
working-source snapshot under .tools/history-cleanup-101/. No push is authorized.
The subsequent user report reproduced a native MatePad storage defect:
TextEncoder.encodeInto('') returns undefined. MailContentFiles now handles
zero-byte text/HTML explicitly while retaining all file/owner/expiry checks;
empty and Unicode file reopen tests pass in the isolated native app. Explicit
Inbox Delete must reach fresh Swift Trash discovery even when cached role or
move-permission metadata is stale. Keep it pending until the receipt, preserve
server MOVE/source checks and show a Trash-specific failure on refusal.
The corrected HAP is installed in place on both devices, still 1.0.1, with
storage identities preserved and no production launch.
See docs/attachment-delete-follow-up.md.

## Version 1.0.1 missing-Archive follow-up

Version 1.0.1 (1000001) is installed in place on both Pura X and MatePad, with
identity/version/hash verified and no production launch. All synthetic host
and native build gates passed; the emulator remained stopped.

The user requested first-use Archive for servers without an Archive folder and
exactly two local history commits, 1.0.0 and 1.0.1. This authorizes local history
consolidation, not a remote push. Preserve the pre-rewrite Git bundle and exact
1.0.0 source snapshot under ignored .tools/history-cleanup-101/.

Create a server Archive folder only during an explicit Archive action, after
source verification. Use the original Swift CREATE and UID MOVE, confirm LIST,
and preserve namespace/ambiguity checks. Folder discovery is read-only. Commit
the confirmed folder with the cache identity move, reject older in-flight folder
snapshots, and keep cached bodies, pictures and attachment origins. Do not replay
uncertain moves or use mailbox-wide EXPUNGE. Preserve tablet split view, the
320 vp account menu, HTML behavior and existing automatic/background pacing.
The user also requested attachment-only loading checks. CID-only images must be
available as on-demand attachments without creating a non-text MIME body; keep
images inline when a text/HTML representation exists. Preserve genuine partial
text errors and attachment size limits.
Use synthetic mail tests and in-place installation without a production launch.
See docs/release-1.0.1.md and its validation record for completed gates.

## Version 1.0.0 attachment and archive round

Version 1.0.0 (1000000) is installed in place on Pura X and MatePad, with device
identity/version/hash verified and no production launch. The user requested
attachments, Archive and this version name after confirming normal performance
in 0.1.28. The tablet account dropdown is capped at 320 vp. Keep the fixed HTML scans, entity parser,
reader rendering and automatic/background timing unchanged. Support receiving
Open/Save and adding files while composing; outgoing files live in private
readable storage with metadata-only draft references. Preserve saved drafts and
Sent attachment files across reopen, and delete only the explicitly discarded
matching draft. Outgoing limit: ten files / ten MiB total; received encoded-part
limit remains four MiB. Never automatically retry an uncertain send.

IMAP Archive uses original Swift UID MOVE with the existing server Archive/All
Mail folder. Preserve cache body/picture/attachment origins across verified UID
changes and Undo. Keep mappingless confirmed moves as explicit offline copies;
never invent server UIDs, use mailbox-wide EXPUNGE or replay uncertain mutations.
A one-time cached-folder role revision upgrade makes Archive available to saved
accounts. Keep tablet split view and existing swipe controls.

Tests are synthetic; do not send mail, access real mail or launch the production
app during installation. The authorized in-place device updates preserve app
identity and accounts. This version label does not authorize public publishing.
See docs/release-1.0.0.md for scope and validation.

## Current on-demand download and profiling round

Previous performance follow-up was 0.1.28 (100028) on both MatePad and Pura X. The
user set aside extra sleeps/background changes to focus on confirmed HTML bugs.
Four measured repeated-suffix scans in InlineImages and bodyPreview now use
forward token processing/bounded attribute starts. All 112 Swift MIME/body,
654 JavaScript and 32 Python tests passed; ARM/x86 native cores and HAPs rebuilt.
Installation was in place, identity/version/hash verified, without production
launch. UI, automatic pacing and background behavior match 0.1.27. Deferred
pacing/IDLE work is only in ignored .tools/deferred-028-background.patch; do not
apply it without renewed scope. This narrow round is complete. See
docs/release-0.1.28.md. The .27 entity-loop fix remains unchanged, and the user
confirmed the formerly stuck message opens. The passive numeric capture is
complete and its collector exited; do not leave or restart a monitor implicitly.

Latest follow-up: the user requested progressive HTML/pictures because messages
stayed loading and became hot. Release 0.1.27 is installed on MatePad and Pura X,
in place with identity/version/hash verification and no production launch. An
explicit MIME port patch fixes a confirmed infinite htmlEntitiesDecoded loop
when an ampersand has no following semicolon. Both native architectures rebuilt;
654 JavaScript, 31 Python and 108 Swift MIME/body tests passed. The helper existed
before .11; the current HTML-preview entry point is first documented in .12.
Do not claim this establishes the cause of every earlier heat report.

The reader now mounts its prepared HTML before its one bounded picture batch,
completing pending local WebResourceResponses as pictures arrive. Do not restore
the old wait-for-all-pictures barrier. Preserve one document, no rescans/reloads,
cached completed attempts, four workers, cancellation on hide/background and
explicit WebView visibility pausing. Body loading has a 45-second UI deadline;
underlying work remains owned until drained. Text/HTML file limits are independent
of metadata JSON; legacy inline limits remain. Native progressive-image display
is not yet verified: the user is using MatePad during a passive numeric capture,
so do not interrupt that use with automated UI tests. See docs/release-0.1.27.md.

The user explicitly reversed bulk downloading: fetch a missing message body when
opened, not during mailbox sync. Release 0.1.26 implements this through
MailMessageLoader, preserving raw mail, fixed prepared HTML and completed picture
attempts. Opening a cached message must not refetch it. A failed body exposes
Retry; optional picture/preparation failures must not hide a usable body. The
legacy MailBodySync queue and migration code remain for compatibility but have
no production worker. Earlier full-sync instructions below describe historical
releases and do not override this behavior.

Automatic account checks, header followups and initial IDLE connections share
AutomaticMailWork: one process-local serial lane, at least three seconds after
completion, a nonblocking timer only while work is queued, and permissions and
lifecycle rechecked before starting. This is a minimum gap, not a three-second
polling interval. Manual refresh, selected-message loading and sending stay
outside that lane. Preserve configured checking intervals and foreground IDLE.

The user explicitly chose readable text/HTML files in app-private persistent
storage, with database references. Use MailContentFiles in filesDir, retaining
metadata and credentials in the encrypted database. Preserve account-bound
opaque references, immutable atomic file writes, original retention timestamps,
and legacy inline-cache migration via bounded RdbText reads. Header/flag updates
must not hydrate or rewrite body files. Never switch back to bulk body/picture
downloads or silently restore encryption for these content files.

The user selected MatePad for automated tests because it is less used and has
a slower CPU. Use the isolated synthetic app there, with bounded SmartPerf and
HiPerf captures and cleanup; no production mailbox access. Keep the emulator
stopped. Pura X is for the user's personal test after an in-place installation.
The first .26 MatePad attempt was interrupted by an accidental user tap, which
the user confirmed; it is not evidence of an automatic body request.

## Earlier on-demand baseline

Development 0.1.26 (100026) is installed on Pura X and, at the user's subsequent
request, on MatePad. MatePad is the user's preferred automated-test device. The in-place upgrades
was identity/version/hash verified without launching production. All 647
JavaScript and 28 Python tests pass; ARM/x86 HAPs compiled, with unchanged Swift
libraries from 0.1.25. The isolated MatePad test passed with 20 pictures, 110 fast
flings, one body fetch, one preparation and offline storage reopen. It confirmed
the large RDB row limit and tiny file-reference records. SmartPerf/HiPerf showed
low idle CPU and a bounded scrolling/opening burst; total battery savings remain
unmeasured. The isolated app was removed and emulator stayed stopped. See
docs/release-0.1.26.md and its validation record. Do not expand this completed
round into another broad performance review without new user direction.

The user subsequently reported heat growing while an email stays open and
explicitly requested a performance log while personally using MatePad. This
authorizes a bounded, passive numeric CPU/thread/memory/temperature/frame capture
of the development app, including PID/UID metadata needed for attribution. It
does not authorize production UI control, mail/log content, screenshots, network
capture or mailbox access. Leave their app running and usable. The .26 install
used the archived signed artifact with the same hash as Pura X. The longer
synthetic reader-idle test is deferred while the user uses the tablet.

Previous baseline:
Development 0.1.25 (100025) is now installed on Pura X only. The user asked to
install there first and will test personally; MatePad remains on 0.1.24. Preserve
that staged rollout until their feedback. Installation was an in-place upgrade,
model/version/hash verified, and production was not launched. All 580 JavaScript
tests, 20 Python tests and 103 Swift tests passed; ARM/x86 native libraries and
production HAPs rebuilt. The prepared .25 native tests have not been built or
executed; emulator stayed stopped. See docs/release-0.1.25.md and its validation
record. This follow-up repairs stale hidden-list gesture gates, completed jobs
whose exact raw cache is absent/pending, and original Swift FETCH assembly across
split responses or unrelated flags. Visible tablet gestures, retry pacing and
immutable saved pictures remain unchanged. Synthetic evidence does not identify
which defect caused the user's real-mail symptom.

Previous complete baseline:
Development release 0.1.24 (100024) is installed on Pura X, then MatePad through
in-place upgrades. Both versions and the matching signed artifact hash were
verified. Production was not launched; saved accounts remain intact. All 572
JavaScript tests, 20 Python tests and 97 Swift IMAP/SMTP tests passed. ARM/x86
native libraries and both HAPs rebuilt with optimized shipping IMAP/NIO/TLS
objects; diagnostic builds remain separate. Host parser CPU fell about 88% for
identical synthetic output, which is not a device-energy measurement.
Sync reads now reuse original Swift IMAP sessions with exact credential owners,
exclusive access, four retained sessions, 16 reads/60 seconds maximum and 15
seconds idle. Pause, failure, expiry and close release them without immediate
request replay. Picture saves use a scalar budget query and read only required
eviction candidates; SQL SUM still scans account rows inside SQLite.

Failed-empty decoding no longer becomes a completed saved body. A one-time
startup repair clears only failed-empty body timestamps and exact old empty
prepared documents, preserving headers, valid shared documents and picture
attempts. Usable partial, valid empty and attachment-only bodies stay complete.
Actual unfinished retries schedule one deadline wake with exponential backoff;
empty/completed queues have no polling timer. Pause, thermal changes and job
deadlines still apply. A due-time crossing is retained; corrupt queue selection
cannot create a one-second wake loop. An explicitly reselected pending reader
can check local cache again, but loaded or currently loading readers stay fixed.

Four native checks passed: original Unicode IMAP reads used one TLS/login
instead of three; six body-classification cases preserved valid empty/partial
compatibility; encrypted RDB repaired one old blank record exactly once; visible
Inbox sync and offline picture reopening settled without repeated body/image
work. The malformed Base64 test initially had the wrong expectation: the
existing decoder preserves raw readable text by design. No strict decoding
change was made. The isolated app was removed and emulator shutdown independently
verified. See docs/release-0.1.24.md and its JSON validation record.

The user dates the battery spike to development builds around 0.1.11, before
Google sign-in removal and separate D-Mail packaging. Pre-publication source
already used unoptimized native objects; version 0.1.11 was reused across source
changes. Automatic full-body sync arrived later, so it cannot alone explain that
earlier onset. The physical heat/battery cause remains unconfirmed. This narrow
sync-cost/blank-body round is complete; do not reopen the broad earlier review.

The user explicitly requested this new snapshot work after the previous bounded
review ended and clarified that bodies and pictures must download during sync,
without opening. The follow-up corrected incomplete coverage: sync now traverses
all pages of registered mailboxes and persists every pending protocol-ID body,
picture stage and cursor without a fixed message-count cutoff. Both installations
are complete; do not reopen the earlier review automatically. Sync prepares and saves a fixed HTML
document before its bounded picture batch. The reader shows saved HTML and
available bytes, including broken pictures, without scanning, downloads, Retry
or automatic replacement. Browser callbacks serve fixed local bytes synchronously,
without database, HTTP or state changes. Preserve tablet split view and native
HTML presentation. See docs/static-message-snapshots.md.

UTF-8 attachment
names and web links are handled correctly for fresh reads. Existing cached bodies
and lost attachment names are not migrated. Optional count/logout work is bounded;
MIME alternative/related/CID scopes and image expansion are bounded and preserved.
The cause of the reported real-email heat remains unconfirmed. No public app-wide CPU quota was
found for these devices. AppGallery was not rebuilt.

## Current bounded review and device test

After the completed review, the user reported high scrolling battery use and
authorized a new narrow investigation on the connected MatePad. They clarified
that fast repeated scrolling is the main trigger, requested pictures in the
scrolling fixture, and reported an APS picture warning despite visible images
being present. Use isolated synthetic HTML/cache/loopback fixtures and bounded
performance counters. Preserve the production reader layout and tablet split
view; experimental render modes stay fixture-only until evidence supports a
production change. Battery current while charging is not app energy usage.

This narrow investigation is complete. Swift and ArkTS malformed-HTML preview
scans, reader tag/attribute scans and confirmed CSS whitespace scans were fixed.
Release 0.1.19 ignored clearly non-content remote images and remembered failed
image loads within one reader attempt. The 0.1.20 snapshot work extended this to
durable saved attempts; 0.1.21 moves preparation to sync. Successful cached
pictures stay intact. The user suggested
SDK 26: a controlled same-source SDK 22/26 MatePad
comparison with 20 pictures and rapid flings passed under both toolchains with
similar listed-process CPU. It does not rule out other SDK-dependent cases or
prove the user's heat cause. Comparison stages precede final parser fixes.
See docs/scroll-power-2026-09-15.md and docs/mail-loading-energy.md. Further body
request cancellation/coalescing and transport byte limits are documented next
steps, not implemented claims. Do not broaden this investigation automatically.

The user capped the remaining review at three rounds. All three rounds are complete. Stop this review; do not open additional
review scope automatically. The final link/long-HTML test and installation
are complete. See docs/review-rounds-2026-09-15.md. The user explicitly authorized testing
on the connected MatePad for this final long-HTML scrolling check. Use the
isolated synthetic app and keep production mail private. Bring the isolated
blank page to the foreground before any automated wake/swipe setup. Preserve
saved production accounts and install upgrades without launching production.
The emulator remains stopped during physical testing.

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
bodies and pictures survive failed refresh. Sync downloads bodies sequentially,
saves immutable encrypted prepared HTML, then loads pictures with a durable
per-account/message attempt record. Completed attempts include failures;
picture-byte expiry cannot silently restart network work. Reader opening is
local-only, with one picture-map read and no scans or Retry. Missing bodies show
pending sync; permitted workers retry failed body requests at a persisted
deadline with increasing backoff. Empty queues remain idle.
Browser callbacks serve fixed memory only. Account/navigation/revision guards
protect reader publication and metadata changes cannot replace its body.

Persist unfinished sync in MailSyncStore, including stage and guarded pagination
checkpoints. Never restore the old 200-job admission cap or first-50 background
slice. Resume after account/store/app changes and automatically follow every page
of registered mailboxes. Prioritize bodies/docs before pictures. A shared Message-ID
document cannot stand in for another protocol ID's body and attachment metadata.
Completed work keeps its original body timestamp; decoder/display bounds on
usable content do not trigger repeated body fetches. Explicit decoding failure
with neither text nor HTML remains incomplete. Background sockets require current job permission
and deadline. Keep failed jobs with backoff and recover stale server cursors from
the head on a later sync. Header discovery must not replace the visible list.
Separate file attachment bytes remain on demand; automatic attachment downloads
were asked as an optional follow-up and have not been selected by the user.

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
arrival/resume. IDLE polling itself does not request bodies; successfully saved
pages enqueue separate body/picture sync work without delaying header feedback.
Pause queued refreshes
in background, composer, scroll and swipe interactions. Preserve bodies, dirty
flags and an overlapping paginated tail. Restore scroll by row ID/pixel offset,
never after user scrolling. ForEach lacks maintainVisibleContentPosition.

Visible Inbox refresh completes after its own headers/cache, before optional
conversation indexing and the companion folder. Keep one companion flight and
only the latest current foreground successor; stale results cannot replace a
newer direct folder load. Recheck foreground after cache awaits before starting
new page requests, and suppress companion requests during composition. A deferred
conversation index resumes from cache once without requiring another arrival.

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
images automatic. Prepare the body and remote pictures during sync, without
opening. Show saved HTML and available pictures as-is, including broken images;
do not scan, retry or replace the open document. Use native ArkWeb
forced dark adaptation for authored HTML; preserve quote colors, expansion and
pictures across theme changes. Group conversations by Message-ID/reply headers
or server thread ID, never subject alone. Collapse older cards and quoted text.

Pause foreground sync during backgrounding, window/ability destruction and
scroll/swipe interactions. Reader teardown does not own or start picture work.
Preserve per-account/message cancellation isolation and resume canceled sync
from its saved document without rescanning; never retry a completed failed
picture attempt. At most four active downloads may finish/cache. Scheduled job
picture access requires its own deadline and current account permission, never
a global foreground override. Preserve good bytes, suppress hidden document
work and reactivate readers without reloading.

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
