# Original IMAP client on HarmonyOS

The current priority is SMTP sending and HTML reading, on a MatePad 12.2-inch running HarmonyOS 6.1.0 as reported by the user. The following Pura X results are historical: The signed ARM HAP installs and launches on that phone and passes four native EmailAddress/MIME tests. Twenty-five native IMAP/account/body checks now pass on ARM; the full UI fixture suite was verified on the x86-64 HarmonyOS 6.0.2/API 22 emulator. See [physical-device evidence](device-testing.md).

The port uses all 43 files from Thunderbird's original `Core/Sources/IMAP` at revision `61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf`, together with the unchanged EmailAddress and MIME modules. `port/swift-imap/upstream-files.json` pins the 43 IMAP source files and ten upstream test files. Thirty-one IMAP files remain byte-for-byte unchanged. The explicit patches adapt OSLog imports, connection/command lifecycle, TLS peer verification LIST capability negotiation and flag selection/update hooks; they do not replace the protocol engine. HarmonyOS uses the existing HiLog adapter, extended with debug/error levels; interpolated data stays redacted. A separate no-output logger is used only for host baseline tests.

`dependencies.json` pins exact upstream SwiftNIO, SwiftNIO IMAP and NIOSSL revisions. `Package.resolved` pins Atomics, Collections and System. The native copies are separate from their pristine host checkouts. The native compatibility patches:

- Prevent Huawei's generated kernel socket header from redeclaring `sockaddr_storage`, using the SDK's musl socket types with its unchanged vsock definitions.
- Return `ENOTSUP` for optional thread-affinity calls absent from Huawei's libc exports.
- Match the opaque `FILE *` imported from Huawei's headers in NIOSSL.

The native build uses Huawei clang and sysroot, the previously built native Swift runtime/Foundation, and either `x86_64-unknown-linux-ohos` or `aarch64-unknown-linux-ohos`. BoringSSL uses Huawei's target libc++ headers and position-independent code. Host C/C++ include environment overrides are cleared for native builds.

## Reproduce the baseline

```sh
./scripts/prepare-imap-dependencies
./scripts/test-imap-upstream
./scripts/prepare-imap-native
./scripts/probe-native-imap-dependencies IMAP
./scripts/link-native-imap
```

Keep the emulator stopped for all these commands. The host runner explicitly selects the installed GCC C++ headers/libraries; Swift's default selection found an incomplete GCC installation on this machine.

The upstream test runner reports 17 functions in 12 suites: 16 execute successfully and `allCommands` is skipped because its live-provider fixture has no credentials. One test expectation adapts Foundation's Linux error wording; the source behavior is unchanged. This does not establish a working server connection. The shared logging extension also passes the existing JMAP host regressions.

All 43 IMAP files and their dependencies compile for the native target. The isolated diagnostic library links 1,059 objects, including its probe, with no unresolved symbols. Its ELF dependencies reference Huawei libc and the native Swift libraries. [The verification record](../port/swift-imap/native-result.json) includes source, library, HAP and log hashes.

The shipping `libThunderbirdCore.so` now combines IMAP/NIO with JMAP, MIME and EmailAddress. `prepare-imap-core-objects` excludes the IMAP build's copies of EmailAddress, MIME and HarmonyLogging, and excludes the diagnostic target. The earlier standalone `libThunderbirdIMAP.so` remains a compile probe only and must not be loaded alongside the shared core.

`libIMAPProbe.so` contains only the diagnostic driver and links against that shared core. Package verification checks that the mail app, IMAP tests and networking/JMAP tests contain byte-identical copies of `libThunderbirdCore.so`, with no leftover standalone mail libraries. The shipping app contains neither diagnostic driver. Hvigor's obsolete native intermediates are cleared when migrating the IMAP test app from the standalone library.

## Native TLS and reading verification

```sh
./scripts/test-native-imap build   # Keep emulator off while preparing both HAPs.
./scripts/test-native-imap device  # Starts, tests, uninstalls diagnostic, stops, verifies stopped.
```

The isolated `org.thunderbird.harmony.imaptest` app passes 24 tests on HarmonyOS 6.0.2/API 22, now using the exact shipping Swift core. The wrapper stops the emulator after the batch; its log confirms `ThunderbirdPhone stopped`. Tests exercise the original Swift client, SwiftNIO IMAP parser, NIOSSL/BoringSSL, and Thunderbird MIME module:

- Three complete TLS login → LIST/STATUS → SELECT → UID FETCH → LOGOUT sessions, including mailbox UIDVALIDITY/UIDNEXT, an unread message and a fragmented MIME literal containing Unicode text.
- Authentication failure, untrusted issuer and wrong hostname rejection.
- A stalled fetch deadline, a dropped connection and cancellation during a pending fetch.
- Oversized literal and mismatched command-tag rejection before the normal command deadline.

The nine direct-client tests are supplemented by fourteen production account/UI tests and one test exercising all 13 original Account body fixtures. Fixture-side observations independently confirm bounded paging, UIDVALIDITY rejection, plain LIST fallback, certificate pinning before IMAP commands, no IMAP session on either invalid TLS endpoint, no writes, `BODY.PEEK[]` on every fetch, and zero remaining open connections. The reader compares the original MIME module's parsed base64 part and decoded Unicode text. The fixture contains only synthetic messages and credentials; no provider has been contacted. Its private CA is supplied only to these test clients, never installed in system trust.

`session-lifecycle.patch` adds an explicit TLS configuration, connection/command deadlines, cancellation that closes pending commands, shutdown of event-loop threads, disconnect failures, command-tag matching and bounded literals. Void commands now await their own tagged completion instead of completing on an unsolicited untagged response. Non-implicit-TLS configurations are rejected explicitly; STARTTLS has not been implemented.

The first shell-executable attempt failed with a socket permission error before TLS. The successful evidence comes from the Internet-permitted HAP, using the same native library. The shell run is retained as diagnostic evidence, not a passing test.

The combined-core regression passes **61 original-core/platform checks**: 24 IMAP/account/body/UI, 32 networking/JMAP/account/reader/change/draft checks, and five mail-app EmailAddress/MIME checks including composer validation. A further 15 historical prototype and storage/UI regressions pass in the same bounded session (76 total). See [combined-core evidence](../port/swift-imap/combined-core-result.json). Reproduce the full batch with `scripts/test-mail-core build`, followed by `scripts/test-mail-core device`; all builds occur before the emulator starts. The device command verifies the exact shared library in all three prepared HAPs before launching.

## Account and reader integration

The shipping account screen defaults to IMAP and accepts a host, implicit-TLS port, email address, login name and password/app password. The email identity is independent from the authentication login and persisted in the encrypted account database (schema 3); migration preserves older credentials without guessing an email address from them. `NativeImapClient` translates the existing presentation DTOs into calls to `thunderbird_imap_account_request`; protocol encoding, TLS, response parsing and MIME decoding remain in Swift. Passwords use the existing HarmonyOS Asset Store lifecycle. Account metadata and cached messages use encrypted RDB storage. The production UI test saves a synthetic account, recreates the screen, restores credentials from Asset Store, opens INBOX and reads Unicode text.

`ImapAccountCore` adds the platform/account boundary while calling the original `IMAPClient`. It retrieves HarmonyOS app trust roots and certificate pins through NetStack. NIOSSL verifies chains and hostnames before an additional leaf SPKI pin check. Huawei may return trust-anchor directories; the adapter loads their PEM contents explicitly because NIOSSL's additional-root API accepts files only. The synthetic app-scoped trust configuration accepts the fixture root; untrusted issuers, wrong names and a same-CA certificate with the wrong public key fail before credentials are sent. Production input cannot supply roots or disable TLS verification.

The reader uses three selected original Account files: `EmailBody.swift`, `EmailAttachment.swift` and `String.swift` (two unchanged). An explicit body patch removes the unused, unimplemented JMAP initializer, exposes the MIME initializer, bounds recursion, preserves attached text and forwarded messages, and avoids logging message contents. All 13 upstream body fixtures pass in the HAP. With IMAP, JMAP, MIME and EmailAddress, the shipping core now compiles **86 original source files, 62 unchanged**. This is selected Account model reuse, not the whole upstream Account module.

Pages contain at most 50 newest messages, fetched by sequence range under an examined mailbox epoch. The adapter rechecks message count, next UID and UIDVALIDITY after each fetch and rejects changed state instead of silently mixing pages. Message identities include mailbox, UIDVALIDITY and UID; a changed epoch cannot open a different message under a reused UID. Paging uses `EXAMINE`; reading uses `SELECT` to discover flag permissions and `BODY.PEEK[]` to avoid marking mail as read. No path issues CLOSE or EXPUNGE. The fixture verifies two pages (50 plus one), stale epochs, changes during fetching, missing UIDs and mismatched responses.

## Read/unread and stars

`message-flags.patch` exposes the existing upstream UIDStoreCommand through `IMAPClient.setFlag`, and retains READ-ONLY and PERMANENTFLAGS in the existing SELECT response handler. The account adapter selects the mailbox, checks UIDVALIDITY, checks the specific flag permission, and fetches the target UID before attempting STORE. It sends exactly one `+FLAGS.SILENT` or `-FLAGS.SILENT` operation for `\Seen` or `\Flagged`; unrelated flags are retained. It waits for the tagged acknowledgement and fetches the flag again before reporting success. Once STORE is attempted, failures are reported as unconfirmed and are never automatically replayed. A refresh can recover a write applied by the server when its acknowledgement was lost.

A missing PERMANENTFLAGS response permits changes; an explicit empty list denies them. The `\*` wildcard permits new keywords and does not grant either of the two system flags. These distinctions follow [RFC 9051 SELECT and response-code rules](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.3.2). The UI checks permissions returned with the message, and the native operation checks again on its fresh connection. Cached content remains non-writable until refreshed.

The 24 IMAP tests include add/remove Seen and Flagged, updated unread counts, preservation of Answered and a custom label, read-only and limited permissions, stale/missing/wrong UIDs, rejected and ignored writes, and a lost acknowledgement. Fixture-side observations confirm 11 explicitly requested STORE commands, including two visible UI star/unstar actions and exactly one write in the lost-reply scenario. All connections close after testing.

## Remaining work

This is an IMAP reading and flag-update milestone verified against synthetic local servers. The user has deferred OAuth. Real-provider interoperability, STARTTLS, automatic configuration, SMTP sending, archive/folder moves, background synchronization and attachment/HTML presentation remain unfinished. The parser currently caps a message literal at 4 MB; larger messages are rejected. IMAP mailbox hierarchy and special-folder roles beyond INBOX still need richer mapping. The entire Account module also depends on SMTP, Autoconfiguration and Apple authentication adapters.

ARM compilation, Huawei signing, installation, launch and native EmailAddress/MIME execution now pass on the Pura X. The live account’s folders, message list and a plain-text body were observed on its screen after the UIDNEXT fix. Twenty-five native IMAP/account/body checks pass on the exact shipping ARM core. Real-provider flag changes and the UI fixture scenario remain unverified on hardware. The unfinished draft journal is preserved in ignored `.tools/draft-journal-wip`; it is not active in production storage or the build.

## Servers omitting UIDNEXT

The Pura X exposed a live-provider compatibility gap: successful EXAMINE omitted UIDNEXT, causing the adapter to reject the mailbox before FETCH. `selection-status.patch` lets the original status method accept explicit attributes. `selectedEpoch` requests MESSAGES, UIDVALIDITY and UIDNEXT only when selection omits UIDNEXT, and rejects missing values or a changed validity/count. No UID is guessed. This follows the compatibility guidance in [RFC 3501 §6.3.1](https://www.rfc-editor.org/rfc/rfc3501.html#section-6.3.1). The two new fixture tests cover two pages, MIME reading, incomplete status and changed identity/count; fixture observations confirm rejected cases never FETCH. The full fixture suite now contains 26 cases (25 without its UI case on the Pura X). Earlier 24-test emulator evidence is retained as historical evidence.

## Authentication error classification follow-up

`authentication-errors.patch` gives the original LOGIN command a narrow subclass
of its capability handler and preserves a typed `AuthenticationFailure.rejected`
through the existing command executor. `Authentication.swift` recognizes matching
tagged authentication NO responses with no code, ALERT, AUTHENTICATIONFAILED,
AUTHORIZATIONFAILED or EXPIRED. Temporary server codes, BAD responses, mismatched
tags, disconnects and timeouts do not request replacement credentials. Provider
response text is never used for this decision or included in the new failure.
The XOAUTH2 handler uses the same classification after the server's tagged result;
an error challenge alone is not proof of rejected credentials.

The account and IDLE-watch adapters map only that typed rejection to the existing
`authenticationRequired` code. A failed CAPABILITY check after successful login
remains a connection/protocol failure. Credential validation and endpoint checks
remain unchanged. This adds no connection, protocol command or automatic retry.
The patch is applied by `scripts/prepare-imap-host` for both host and native stages;
pinned upstream files and their hashes remain unchanged.

`AuthenticationTests.swift` prepares a private ephemeral certificate and drives the
actual Swift client over loopback TLS through rejected, accepted, dropped, stalled,
temporary-error and post-login capability scenarios. `XOAuth2Tests.swift` separately
checks malformed tags, socket loss and safe typed rejection using NIO's embedded
wire handlers. On 2026-09-15 the focused host run passed 22 tests across five
suites, including 19 actual loopback TLS scenarios. The complete IMAP/SMTP host
suite passed 79 tests across 27 suites. The first sandboxed run was blocked by
local socket creation permissions before the TLS scenarios; the permitted
loopback rerun passed. These are host protocol results, not HarmonyOS runtime or
real-provider evidence. Native build/runtime and installation evidence belongs
in the completed release record.

## Bounded optional counts and account cleanup

`account-session.patch` adds an explicit optional LOGOUT timeout to the original
client and `VoidCommand`; their defaults remain unchanged. Account requests use
one second for that final command, and skip it if an optional failure already
closed the connection. The existing command executor closes a timed-out channel.
`AccountSession.swift` separately attempts shutdown and preserves the original
operation result even if cleanup throws. A failed operation skips LOGOUT; its
original authentication, transport or unconfirmed-mutation result is retained.
There is no extra connection or automatic retry of STORE, SMTP or APPEND.

The shared optional folder-count helper uses a monotonic five-second budget,
with each STATUS limited to at most two seconds and to the remaining whole
seconds. It stops querying after the first failure or when less than one second
remains. Complete counts supplied with LIST need no STATUS; incomplete supplied
counts and all folder identities survive an optional failure. These counts remain
optional decoration. Mandatory UIDVALIDITY checks and the existing checkInbox
count deadline are unchanged. The account bridge still has its existing overall
30-second deadline; this change does not add connection reuse or alter SMTP.

`AccountSessionTests.swift` runs the actual Swift client against a synthetic
loopback TLS peer. It covers stalled/rejected optional STATUS, supplied LIST
counts, stalled LOGOUT, a confirmed STORE followed by stalled LOGOUT, and a
lost STORE acknowledgement. Injected cleanup failures verify preservation of a
proved result and of original authentication/uncertain-operation failures.
`TLSFixtureSupport.swift` supplies the ephemeral local certificate shared with
the authentication regressions. The new patch/helper are registered explicitly
in `scripts/prepare-imap-host`, which also stages the native source build;
upstream source hashes and defaults for other callers remain unchanged.

The focused host run on 2026-09-15 passed 32 tests across seven suites, including
all six cleanup/count TLS scenarios and 19 authentication scenarios. The stalled
STATUS case retained the three LIST folders in 2.003 seconds with exactly one
STATUS; the supplied-count case made zero STATUS requests. A confirmed flag
change survived a stalled LOGOUT in 1.009 seconds with one STORE and two explicit
UID/FLAGS reads. A lost STORE acknowledgement produced the original unconfirmed
result with one STORE, no retry and no LOGOUT. These timings are synthetic host
measurements, not real-provider or HarmonyOS performance evidence.

The clean full IMAP/SMTP host build passed 89 tests across 29 suites in 4.137
seconds. A clean build was required after the MIME model's stored layout changed;
incremental consumers had retained an older layout. The full run includes the
concurrent MIME reconstruction corrections, the original composition regressions,
and all authentication/watch/check tests. Native integration remains a separate
gate with freshly rebuilt dependent objects.

## Inbox previews

`message-preview.patch` retains RFC 8970 PREVIEW values in the original Swift
Message component/merge path. Upstream already requests PREVIEW (LAZY) when
advertised; previously its decoded value was discarded. `preview-fetch.patch`
adds an optional UID FETCH deadline without changing normal command defaults.
Both are applied explicitly by `scripts/prepare-imap-host`; pinned upstream
source hashes remain unchanged.

When no server preview exists, the existing header FETCH also requests
BODYSTRUCTURE. `PreviewSample.swift` selects one inline text/plain leaf, falling
back to text/html, and derives MIME metadata from that structure. It excludes
attachment parts and attached multipart trees. The same connection fetches a
maximum of 2,048 encoded text bytes per missing preview, at most 50 messages
(100 KiB), grouped into at most four UID FETCH commands. Each group has a
one-second timeout; new groups stop after three seconds. Failed, incomplete,
duplicate-UID and oversized samples cannot replace the already verified header
page. No sample is stored as a downloaded reader body or marks mail Seen.

Previously cached preview identities skip these samples on later Inbox refreshes.
Header-only refreshes preserve saved summaries; existing downloaded text/HTML
bodies with blank summaries recover previews locally without server access or
changing retention timestamps. A text part with no useful content in its initial
sample may remain blank. Notification polling remains limited to UID/FLAGS and
does not sample bodies. A sample that ends in the middle of a Unicode character
uses the original strict decoder with at most 12 encoded trailing bytes trimmed;
interior corruption is not replaced and the declared charset is preserved.
The prepared synthetic gate is
`scripts/test-emulator-message-preview`; its test evidence belongs in the release
record after execution.

## Split body responses

`fetch-assembly.patch` retains attributes received across multiple FETCH records
for the same sequence number. The existing `Message.merging` implementation
preserves earlier body sections when later sections or flags arrive. Conflicting
UIDs close the exchange; selective readable-body requests accept exactly one
explicit matching UID and ignore unrelated flag updates. They never combine
sections from different sequence numbers. The patch is applied explicitly by
`scripts/prepare-imap-host` for both host and native staging, leaving the pinned
upstream files and hashes unchanged.

`FetchAssemblyTests.swift` exercises the actual NIO wire decoder for combined
and split Unicode bodies, flag updates, UID conflicts and missing sections.
The shipping native sync fixture also returns split MIME/body responses and
unrelated flags. See `docs/release-0.1.25.md` for completed runtime evidence.

## Archive creation and attachment-only messages (1.0.1)

`ArchiveCreation.swift` uses the original CREATE encoder and UID MOVE transport.
Existing Archive/All Mail is preferred. When none exists, read-only planning
uses one personal NAMESPACE (two-second optional deadline), or an unambiguous
visible root/Inbox hierarchy. Only an explicit Archive operation validates the
source UID/UIDVALIDITY and write selection, creates once, confirms the exact
selectable folder with LIST, revalidates the source, and sends MOVE. A tagged
ALREADYEXISTS can proceed to verification; other refusals and unconfirmed results
never move or replay. `archive-creation.patch` registers these wrappers without
changing upstream hashes. Namespace queries and normal refreshes never CREATE.

The returned actual folder is cached atomically with the new UID identity.
Mailbox snapshots capture a mutation revision before LIST; a response older than
a confirmed folder mutation cannot erase it. UI publication reads that accepted
cache and retains account/navigation ownership. The Inbox's optional prospective
destination is an action hint, never a listed folder before server confirmation.

`ReadablePlan` retains CID-only pictures as attachment metadata when no nonempty
text/HTML representation exists. Empty text stubs remain valid, required related
root MIME metadata stays available, and image payloads are fetched only through
attachment actions. Body-only limits on those images cannot fail message open.
Nonempty declared text and ordinary HTML/CID plans retain their partial/error
handling. Synthetic tests exercise standalone/multipart PDFs and CID images,
empty stubs, large images, offline cache reopening, and bounded request counts.
