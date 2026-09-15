# Protocol and operations review — September 2026

This review starts from development release 0.1.14 and preserves the existing
worktree. It covers the active mail-operation, protocol, send, attachment,
discovery and OAuth integration. It does not read a real account, launch the
production app, send real mail, run a device/emulator or change release metadata.
The changes continue to use Thunderbird's pinned original Swift clients and
explicit port patches; no upstream source or manifest hash was replaced.

## Confirmed defects corrected

| Path | Previous behavior and consequence | Change and evidence |
| --- | --- | --- |
| `harmony/entry/src/main/ets/mail/MailOperations.ets`, `overlay` | Every pending read/star/move projection JSON-serialized and parsed the whole cached email, including large HTML. Repeated row/count work copied content it did not change. | Shallow record copy with a new modified keyword or membership array. The immutable body strings are shared. A deterministic test repeats flag and move overlays over a 2 MB body, observes zero JSON serialization, verifies original frozen arrays and one eventual server mutation. |
| `mail/MailUnreadStatus.ets`, `refresh` | Cached unread scans loaded/retained bodies for every mailbox despite using only membership and flags. | Uses the storage review's `view(account, mailbox, true, false)` header projection. Five status tests assert this argument and preserve account/operation overlays. `JmapEmail.cachedBodyAvailable` is local ranking metadata only, not permission to treat a bodyless row as a downloaded body. |
| `mail/imap/NativeImapClient.ets`, `connect` | Concurrent callers started duplicate credential lookups and native connect/authentication requests. | One in-flight discovery is shared; completed sessions are copied before returning. Failure clears the flight without an automatic retry. Tests hold the native call and verify one credential lookup/request, isolated returned sessions, and later explicit recovery. |
| `mail/imap/NativeImapClient.ets`, `emailPage` | Optional cached-preview IDs embed mailbox names. Hundreds of long IDs could overflow the 128 KiB native request envelope, rejecting the entire header refresh. | Hints now have a 32 KiB combined budget, 500-candidate limit, deduplication and opaque-ID validation. Tests combine long synthetic mailbox IDs and a maximally escaped credential envelope; required page/state fields survive and the native request fits. Dropped hints may cause bounded preview sampling again; no additional connection is introduced. |
| `mail/smtp/BackgroundSend.ets`, `perform` | A failed post-acceptance draft-state write skipped saving the accepted message to local Sent. | Attempt the two durable copies independently, retain accepted/no-replay state and report `sent_save_error` if either fails. Two injected-storage-failure tests verify both directions, one submission and one recipient-history update. |
| `port/swift-smtp/harmonyos.patch`, `SMTPClient.send` | Event-loop shutdown could throw after SMTP DATA received 250. The bridge then returned a network failure even though delivery was accepted. | Preserve the protocol outcome across channel/group cleanup. `finishSMTPDelivery` attempts cleanup but returns/throws the original result. Two tests drive the actual embedded SMTP handler through DATA: 250 remains success despite injected cleanup failure; a dropped DATA acknowledgement remains `deliveryUnconfirmed`. |
| `mail/attachments/AttachmentFiles.ets` | Opening even a fresh attachment scanned all account attachment folders synchronously. Same-file concurrent loads duplicated downloads and shared a `.part`; cleanup could delete an active temporary file; an unchecked short write could be renamed as complete. | Fresh lookup is local and direct. Load/decode/write/rename, pruning and picker copy use asynchronous APIs. Same-file requests share one job. Pruning excludes active files. A complete write is required before atomic rename; nonprogress/invalid counts and more than 128 writes fail and clean the temporary file. Account-removal revisions reject late downloads. Seven injected-filesystem tests cover cache hits/no directory scan, shared work, short writes, failed-write preservation, pruning during write or an already queued orphan unlink, account removal and explicit retry. |
| `mail/oauth/LoopbackBrowserSignIn.ets`, `signIn` finalization | A listener-close or native-session-cancel error could replace completed tokens, a primary browser failure or cancellation. | Attempt both cleanups independently without replacing the primary outcome. Three synthetic lifecycle tests cover successful tokens, browser error and cancellation while listener startup is pending; late callbacks remain rejected. |

Paths abbreviated with `mail/` in this table are under
`harmony/entry/src/main/ets/`. Attachment retention remains seven days from the
file write; the existing 4 MiB decoded / 6 MiB base64 bounds remain. No attachment
is downloaded to populate a list or unread count. Account removal's explicit
synchronous directory removal remains unchanged apart from invalidating pending
attachment jobs; it is not part of ordinary browse/open/save paths.

## Send and mutation safety traced

`BackgroundSend.queue` marks a durable outgoing draft as `sending` before SMTP,
keeps one submission active per account, snapshots its account/settings/draft and
survives navigation. Accepted draft IDs cannot be queued again in that process.
The bridge validates before network work, uses connect and transaction deadlines,
and does not return a timeout while DATA could still be sent later. The SMTP
handler resolves acceptance only after DATA 250. Dropped acknowledgement, parser
or Node-API response uncertainty stays `deliveryUnconfirmed`; no automatic resend
is added. Explicit SMTP rejection remains distinct from uncertain delivery.

After acceptance, `SmtpAccountCore.saveSent` is nonthrowing and returns the Sent
copy result separately. APPEND rejection/lost acknowledgement does not undo SMTP
acceptance. Gmail auto-save is limited to the verified matching SMTP/IMAP server
and login pairing; generic accounts select declared or unambiguous existing Sent
metadata without creating or guessing a folder. SMTP envelope recipients include
Bcc while MIME output omits it. Recipient history is learned only after acceptance.
The cleanup regression injects a local failure; it is not a claim that an actual
HarmonyOS event-loop shutdown failure was observed.

MailOperations captures the original account/service, gates each message against
simultaneous flag/move work, begins a persistent dirty mutation before network,
and persists acknowledgements to the original cache after navigation. Uncertain
mutations retain conservative dirty state and are not automatically replayed.
Native flag changes verify UIDVALIDITY and one explicit target FLAGS response
before/after STORE. JMAP changes use mailbox rights, selected-account binding,
correlated method responses and `ifInState`; undo validates expected memberships.
These server checks were retained rather than removed to reduce request counts.

## Coverage ledger

| Area | Source read and traced in this review |
| --- | --- |
| Operation/status layer | `MailOperations.ets`, `MailUnreadStatus.ets`, `HarmonyMailClientFactory.ets`; storage integration was coordinated with its owner. |
| ArkTS client interfaces | `mail/jmap/JmapClient.ts`, `NativeJmapAccountCore.ets`, `HarmonyJmapTransport.ets`; `mail/imap/NativeImapClient.ets`. The JMAP model/interface, original-native facade and legacy/prototype transport were distinguished. |
| Send/reply/attachment layer | `mail/smtp/NativeSmtpClient.ets`, `BackgroundSend.ets`, `SentMail.ts`, `Reply.ts`; `mail/attachments/AttachmentFiles.ets`. |
| Discovery/OAuth facade | `mail/discovery/NativeMailDiscovery.ets`; `mail/oauth/NativeBrowserOAuth.ets`, `LoopbackBrowserSignIn.ets`, `LoopbackOAuthListener.ets`, `OAuthFailure.ets`, `RegisteredMailOAuth.ets`. |
| Shipping native entry points | `harmony/entry/src/main/cpp/napi_init.cpp`; `port/swift-bridge/JmapAccountBridge.swift`, `JmapTransport.swift`, `JmapReaderBridge.swift`, `JmapWriteBridge.swift`, `MimeBridge.swift`; `core/Mime.ets` call-site inventory. |
| IMAP/SMTP account adapters | `port/swift-imap/ImapAccountCore.swift` operations and global deadline, `ImapModels.swift` identity/request models, `ImapTrust.swift`, `ReadableBody.swift`, `PreviewSample.swift`, `FlagMutation.swift`, `ReplyHeaders.swift`, `XOAuth2Command.swift`, `AppendSent.swift`, `SmtpAccountCore.swift`. Inbox checking and watch branches are owned by the notification review, not counted as independently re-reviewed here. |
| Active IMAP adaptations | `session-lifecycle.patch`, `account-hooks.patch`, `flag-mutation.patch`, `oauth.patch`, `preview-fetch.patch`; readable-part and Account body/CID behavior traced through the active adapter/source. Existing preview byte/group/time limits were retained. |
| Active original SMTP | Effective prepared `SMTPClient`, `SendHandler`, `ResponseHandler`, `RequestEncoder`, original `Email`, `ByteHandler`, `MessageHandler`; explicit `harmonyos.patch`, `oauth.patch`, `sent-copy.patch`; `MessageSafety.swift`, `MessageData.swift`, `ComposeBody.swift`, `TlsHandler.swift`. SMTP patches were also strictly applied in memory against pinned originals before the coordinated host run. |
| Active original JMAP | `account-context.patch` and `message-writes.patch` in full, draft-creation adaptation, session/get/query/write flow in the native adapters. Original selected-account, state, response correlation and bounded transport remain in force. |
| MIME/text adaptation | `port/swift-mime/PartParsing.swift`, `HeaderDecoding.swift`, Account body decoding/CID replacement paths, plus readable-part and preview adapters. This is a focused traversal/decoding/output-limit review, not a fresh exhaustive audit of every MIME/EmailAddress model. |
| Native discovery/OAuth | `port/swift-autoconfiguration/Discovery.swift`, `ConfigDocument.swift`, `BrowserOAuth.swift`, `OAuthBridge.swift`, `OAuthTokenTransfer.swift`, `MailOAuthProvider.swift`, `GoogleDesktopAuthentication.swift`. No private local registration was opened. |
| Runtime trust boundaries | `port/swift-imap/CHarmonyIMAPTrust/trust.c`, `port/swift-runtime/HarmonyTrust.c`; trust comes from platform policy, not request JSON. |
| Test/build distinction | `scripts/prepare-smtp`, `scripts/prepare-imap-host`, `scripts/test-imap-upstream`, `scripts/test`; `port/swift-imap/napi_imap.cpp` is a disposable diagnostic bridge and is not the shipping Node-API entry point. |

Browser OAuth keeps PKCE/state and one-use native sessions, rejects callbacks
outside the registered loopback authority, bounds listener clients and response
bytes, clears handlers/timers on close, and does not log callbacks or tokens.
The default disabled Google browser entry remains unchanged; retained Microsoft
and saved-token paths were reviewed. OAuth storage leases/reconnect replacement
are covered jointly by the storage and UI reviews, rather than claimed as new
coverage of the entire AccountStore here.

## Remaining limitations and follow-ups

- **Connection setup cost:** ordinary one-shot native IMAP account requests create
  their own authenticated client (`ImapAccountCore.swift:214`); persistent watch
  lifecycle operations and local watch snapshots are exceptions. Each native JMAP operation
  creates a transport and downloads the JMAP session
  (`JmapAccountBridge.swift:79`). JMAP's bounded URLProtocol also uses an inner
  ephemeral session per request (`JmapTransport.swift:43`). Discovery coalescing
  removes duplicate concurrent `connect` calls but is not a connection pool.
  Connection reuse needs a separate serial ownership/cancellation/credential
  invalidation design and protocol fixtures before replacing this boundary.
- **IMAP authentication error classification:** `ImapAccountCore.swift:221`
  maps all failures during login/XOAuth2 (including post-auth capability refresh)
  to `authenticationRequired`. A timeout/disconnect there can therefore suggest
  reconnect even when credentials remain valid. XOAuth2's failure handler also
  collapses some transport failures. Native source is left unchanged in this
  review round; correcting the distinction needs protocol-level rejected-auth,
  stalled-auth and post-auth-disconnect tests. This finding does not establish
  the cause of the historical live Gmail problem.
- **Worker admission/cancellation:** shipping Node-API work is asynchronous;
  Swift semaphore waits run on native workers, not ArkUI. There is no global
  priority/admission budget or exposed cancellation token for queued native
  reads. Independent slow requests can occupy workers until protocol/global
  deadlines. No worker-starvation or energy measurement was performed.
- **Optional IMAP metadata budget:** mailbox count enumeration checks a wall
  budget between commands, while a single STATUS retains its command timeout.
  Generic successful read cleanup can still surface a shutdown failure. The
  arrival checker has its own optional-count protection, covered separately.
- **MIME/CID edge cases:** readable reconstruction flattens selected MIME leaves
  into a multipart/mixed body. Repeated Content-IDs in different related scopes
  and raw substring Content-Location replacement can pick/corrupt the wrong URL;
  generic octet-stream CID images are not selected as image leaves. A 2,000,000
  character output prefix can cut an expanded data URI. These are source-level
  edge cases, not demonstrated causes of the supplied remote-image screenshot;
  no broad MIME rewrite is included. Exact scoped/prefix-collision fixtures are
  still needed before changing original Account behavior.
- **MIME diagnostic and synchronous address entry:** `MimeBridge.swift:20` caps
  depth/parts but duplicates nested encoded payloads without an aggregate JSON
  output budget. Its `core/Mime.ets` exports have no production page callers in
  the inspected tree. The small synchronous `validateEmailAddress` Node-API
  entry lacks its own length cap (`napi_init.cpp:117`); AccountStore validates a
  512-character bound, while setup relies on its UI inputs. Neither diagnostic
  output nor arbitrary-sized address validation was load-tested here.
- **Less frequent local costs:** attachment account deletion remains synchronous;
  large reply/forward construction still scans body strings when explicitly
  invoked. Neither is a repeating background timer. No claim about actual
  device heat, battery drain or measured power reduction is made.

The full vendored SwiftNIO/NIOSSL/Foundation implementation, inactive upstream
Thunderbird UI/modules, platform SDK internals, real-provider behavior and
physical thermal/power measurements are outside this file review. Production
build/type checks and any prepared native UI gates are integrated by the root
review. Host tests alone are not a substitute for those checks.

## Verification

Focused tests completed before integration:

- `tests/protocol-work.test.cjs`: 5 passed.
- `tests/mail-unread-status.test.cjs`: 5 passed.
- `tests/send-diagnostics.test.cjs`: 8 passed, including 2 new accepted-write failures.
- `tests/attachment-files.test.cjs`: 7 passed.
- `tests/oauth-signin-cleanup.test.cjs`: 3 passed.
- `tests/oauth-reconnect.test.cjs`: 7 passed; notification credential invalidation
  is asserted against the replaced account, including reconnecting an account
  other than the currently visible account.
- Coordinated native host command
  `scripts/test-imap-upstream --filter 'InboxWatchTests|InboxCheckTests|SMTPDeliveryCleanupTests'`
  passed 14 tests across 3 suites, including both new SMTP cleanup tests. The
  notification reviewer ran this once with exclusive staging/build ownership.
- `git diff --check` passed at the focused review checkpoint.

The protocol-review checkpoint of `scripts/test` passed **398 JavaScript tests
across 43 files and nine Python tests**, including the final held-unlink, Sent
projection and UI lifecycle regressions. Its log is kept locally at
`.tools/review-protocol-host-2026-09.log`. Peer review found no further issue in
the final attachment locking order or OAuth outcome cleanup. No version bump, device installation or emulator session is
performed by this protocol review.
