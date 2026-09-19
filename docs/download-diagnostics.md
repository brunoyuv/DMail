# Download diagnostic build on main 1.0.4

> Historical 1.0.4 investigation: the user requested removal of this in-app debug
> feature in 1.0.5. See [release 1.0.5](release-1.0.5.md).

Current build: `1.0.4-download-log-4-inbox-cache` adds the user-requested
[foreground Inbox prefetch](foreground-inbox-cache.md), with separate `prefetch`
attempt labels and the confirmed singlepart correction included.

The second uploaded export exposed a missing singlepart
MIME-header section despite a complete body transfer. The corrected build is
`1.0.4-download-log-3-singlepart-fix`, with detailed logging retained. See
[the diagnosis and correction](outlook-singlepart-header-fix.md). Earlier logger
versions and their evidence are documented below.

At the user's request, the main 1.0.4 source now includes local download
instrumentation. The signed in-place Pura X update is identified in Settings as
`1.0.4-download-log-1`; the package version remains 1.0.4 (1000004).
The preceding transient OAuth error correction remains included. No commit,
remote push or public release was performed.

## Using it

Open D-Mail normally and reproduce the failed download. Then open Settings →
Download diagnostics → Export download log and choose a destination using the
system file picker. Recording starts enabled for this diagnostic build. Turn it
off when finished; Clear download log removes the retained diagnostic history.
Both controls persist across application restarts. Export is user-operated and
there is no automatic upload or collection of a production mailbox.

## Evidence retained

The foreground logger stores up to 128 sanitized records, with the compact
stored JSON capped at 120,000 characters, in app-private preferences named
`mail_download_diagnostics_v1`. Each record has a timestamp, numeric attempt
identifier, safe stage/error categories and elapsed time. Reader flags record
only whether the sender belongs to the Microsoft domain family, whether the
preview is empty, and whether the body is partial or has decoding trouble.
Sender addresses, sender names, subjects, mail IDs, mailbox names, message text,
URLs, credentials, tokens and provider response strings are excluded. The domain
flag is a diagnostic grouping, not a claim of sender authenticity. A numeric
attempt identifies one local operation, not a stable message across retries.

IMAP requests return an optional bounded trace from the original Swift protocol
client: connection, authentication, selection, headers/previews, body structure,
part ordinal/advertised size/received size, assembly, mailbox verification and
decoding. Native events are closed-enum categories and bounded numbers, with at
most 96 steps. Error classification never formats associated error text. The
ArkTS logger independently allowlists fields again before persistence/export.
Credential lookup failures before entering the native bridge are recorded too.
Reader records distinguish cache, queue, download, decode, save, document and
math stages. Successful operations are retained to show recovery after failure.

Logging does not change protocol requests, server retry policy, credentials,
mail retention, app/storage identity or native ABI entry points. It has no
polling timer; preference writes are coalesced during pending flushes, and a
logging-storage failure cannot reject a mail operation. Settings reports storage
or export failure. An abrupt process termination can lose an unflushed tail;
this is a bounded diagnostic history, not a crash-proof journal.

## Lifecycle limits

The reader has a 45-second UI deadline and the native bridge a 30-second wait
limit. The native timeout records a snapshot of the active stage before
requesting task cancellation. Unfinished work remains owned until it drains;
the UI timeout does not prove every underlying operation has stopped. The shared
body lane can therefore delay another uncached read behind unfinished work.
Native connections have cleanup paths and IDLE/background work has lifecycle
gates, while stores, queues and this bounded logger are app-lifetime services.
There is no claim that every module has a strict finite execution deadline.

## Validation and installation

- The full host run passed 791 JavaScript and 40 Python tests. Two added loader
  diagnostic tests also pass, for 793 JavaScript tests in the resulting suite.
- The focused original Swift IMAP run passed 43 tests, including the 12-case
  sender/login matrix and bounded, privacy-safe trace assertions on actual
  synthetic TLS body reads. The failed part stage and healthy assembly stage
  are verified across the repeated failures.
- Logger tests exercise restart persistence, bounds, exclusion of private
  fields, disable/clear, storage failure isolation, native/credential errors,
  selected-destination export, short writes and closing on export failure.
  Loader tests cover network/decoding/storage distinctions and retaining work
  after a UI timeout. One added assertion initially inspected the wrong argument
  index in the test recorder; correcting the assertion required no app change.
- The ARM64 native core and signed HarmonyOS HAP compile. Verification establishes
  current production source parity, library hashes, version and the diagnostic
  marker in the signed bytecode. The pinned upstream sources/hashes are intact;
  instrumentation is confined to existing port adaptations and app code.
- The verified Pura X was updated in place. Installer success, signed input hash,
  bundle/version and unchanged account/storage identities were checked. The
  production app was not launched and its process was absent afterward. No
  production mail was accessed; native diagnostic export is not yet device-tested.
  MatePad was untouched and the emulator remained stopped.

See [validation record](download-diagnostics-validation.json). Local build,
synthetic test and install evidence stays under ignored `.tools/outlook-logged-104/`.

## Comprehensive follow-up: 1.0.4-download-log-2-detailed

The user requested one comprehensive logging update after uploading five failures
from the first logger. All five reached successful authentication/selection, then
rejected the first body part and failed assembly. Advertised sizes were 80,407
and 97,088 bytes. Inbox checks still succeeded after these attempts. The original
`partRejected` category did not distinguish its individual checks, so that log
could not establish which condition rejected the part. The uploaded original is
preserved locally; it was not added to a public record or sent to a service.

The detailed update preserves mail behavior and records these distinctions:

- Each validation reports actual header/content byte counts (`-1` means absent),
  advertised bytes, accepted cumulative bytes and the numeric MIME section path.
  Rejections separately identify missing header, missing content, header limit,
  content limit, unexpectedly empty content, aggregate limit or MIME parsing.
- MIME parsing reports missing separator, oversized header/input, duplicate
  recognized header (a fixed field number, never its value), invalid content
  type, successful header size and header-presence flags. Original MIME errors
  have distinct safe categories, including charset, boundary, decoding,
  impossible content type, missing data and malformed headers.
- Body structure records numeric paths/depth/child counts, advertised sizes,
  attachment/CID indicators and fixed media, encoding and charset categories.
  Plans report readable/metadata/attachment counts, limits and partial status.
  Received section sizes, omitted assembly nodes and failed metadata are visible.
- The explicit `download-diagnostics.patch` observes original command outcomes
  before the existing generic error mapping. It records actual timeout events,
  command deadlines, safe server OK/NO/BAD and selected response-code categories,
  and promised/received literal sizes. It never logs commands containing login,
  mailbox or UID values, nor server prose. Callback handlers retain the originating
  trace explicitly because NIO callbacks do not inherit Swift task-local context.
- Logout and shutdown have start/success/failure events. The initial request
  records the number of active diagnostic native requests. If the bridge already
  returned at its deadline, eventual completion/cleanup is retained in an
  eight-entry in-memory queue and attached to the next diagnostic native request.
  `lateCompletion` uses the original attempt number; its trace contains the elapsed
  timing. No polling or extra server requests are introduced. If the app process
  terminates before another native request, that in-memory late tail is lost.
- Reader and native download events share an attempt number. Native client and
  message references use bounded in-memory mappings to anonymous numbers, allowing
  repeated failures to be correlated within a process. No real identifier or
  mapping is persisted, and these numbers do not identify messages across restarts.
- Routine history retains at most 512 records/1,000,000 compact JSON characters.
  A separate failure history retains up to 32 records/400,000 characters, so later
  successes do not immediately displace failures. Each native trace retains 512
  events, preserving its first event and latest events, plus an explicit dropped
  count if needed. Storage uses chunks of at most 6,000 characters and writes only
  changed chunks. Old records migrate, and disabling/clearing remain available.

The export includes a schema version and numeric-field legend. No message body,
subject, address, header value, URL, token, password or raw exception/provider
text is recorded. This is detailed structural evidence, not a packet capture.
Abrupt termination can still lose an unflushed tail. The logger does not change
failed-part acceptance, UID verification, limits, automatic retry, cancellation,
cleanup or the user's mailbox. The app remains on main **1.0.4 (1000004)**; the
Settings marker identifies this diagnostic variant.

Validation: **795 JavaScript, 40 Python, 45 focused Swift IMAP and 116 Swift
MIME/body tests pass**. The tests distinguish all nine synthetic rejection cases,
accept healthy bodies at both sizes observed in the upload, check raw timeout
capture and actual loopback TLS literals, verify bounded traces/private-field
exclusion, correlate reader/native attempts, retain failures through 550 later
successes, reopen and clear chunked storage, and exercise late-completion draining.
ARM64 compilation and signed source/library/bytecode checks pass. Physical
production mailbox tests and automated production UI/export tests were not run.
See [detailed-build installation validation](download-diagnostics-detailed-validation.json).
