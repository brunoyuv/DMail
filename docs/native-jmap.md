# Original JMAP module on HarmonyOS

All 23 Thunderbird JMAP source files compile in Swift 6 language mode for
`x86_64-unknown-linux-ohos`. The mail application's account discovery and mailbox
loading, paged message lists and plain-text reading now call the original client
through a Node-API/Swift bridge. JMAP joins
EmailAddress and MIME in `libThunderbirdCore.so`, with one copy of each module.
Read/unread, stars, archive/undo and draft creation also use Swift workflows.
All current connected protocol entry points select the native core in production.
The shipping facade requires the Swift core. The older ArkTS protocol engine and Remote Communication Kit transport have moved into the test source set and are excluded from the production HAP. The connected UI uses a native client factory; its historical UI fixture injects a separate test-only factory.

The [facade separation record](../port/swift-jmap/native-facade-result.json) includes hashes of the shipping HAP and disassembled Ark bytecode. The native factory and bridge are present; the historical protocol and RCP classes appear only in the test HAP. Four host checks cover the mandatory-core boundary, coalesced discovery, captured draft/undo input and failure handling without protocol fallback or write retries. All 32 native networking/JMAP tests and five main-app tests passed after extraction. The separate 15-test historical/UI suite also passed after adding display wake and lock-screen handling for fresh emulator sessions. Both emulator sessions ended stopped.

The baseline is Thunderbird iOS revision
`61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf`. Its checkout remains unchanged.
`port/swift-jmap/upstream-files.json` pins 41 source, test and resource files.
The preparation script checks the revision, clean source paths and every hash,
then copies them into `.tools/swift-probe/native-jmap/source`.

The explicit `harmonyos-imports.patch` changes only imports in four files:

- `JMAPClient.swift`, `URLSession.swift` and `URLRequest.swift` conditionally
  import FoundationNetworking, where non-Apple Swift supplies URLSession types.
- `JMAPClient.swift` selects HarmonyLogging when OSLog is unavailable.
- `Email.swift` guards its unused UniformTypeIdentifiers import.

Additional patches preserve the account flow's settings and support reading:

- `account-context.patch` injects URLSession, the configured discovery URL and
  selected account into the original client, and decodes the session state.
- `response-correlation.patch` checks response count, call ID, method name and
  account ID against the original requests before decoding results.
- `message-reader.patch` extends the original query/get methods with pagination
  options and response state, adds typed body values to `Email`, maps `partId` and
  `blobId` correctly, and accepts fractional dates while retaining offset dates.
- `message-writes.patch` extracts the original mailbox update encoder into a
  generic encoder shared with Email, adds message-change workflows, retains SET
  state, validates acknowledgements and maps method/per-message errors. It also
  enforces the server's request-size limit before posting any method.
- `draft-creation.patch` adds lossless draft input and a creation workflow using
  the shared SET encoder, with distinct rejected and uncertain outcomes.

Across the six patches, eleven source files change and 12 remain byte-for-byte
identical. Request construction, response decoding and mail models use upstream
code with those explicit extensions. The app compiles 40 original source files
across EmailAddress, MIME and JMAP, with 29 byte-for-byte unchanged.
HarmonyLogging implements the small Logger interface used here through HiLog;
interpolated values are redacted, preserving privacy for mailbox names.
This adapter is not a complete OSLog replacement.

```sh
./scripts/build-native-jmap
./scripts/test-jmap-upstream
./scripts/test-native-network build  # Build combined networking/JMAP test HAPs
./scripts/test-native-network device # Test and stop emulator automatically
```

The build also uses the unchanged EmailAddress module. The candidate shared
library links with `--no-undefined` against the native FoundationNetworking and
runtime libraries. Source and artifact hashes are recorded in
`port/swift-jmap/native-result.json`. Upstream warnings about retroactive Codable
conformances remain visible. No source changes were made to silence them.

## Runtime evidence

The combined HAP suite passes all 32 checks: six [networking tests](native-networking.md),
four original JMAP integration tests, five production account-bridge tests and
six production reader-bridge tests, six production message-change tests and five
production draft-creation tests.
The four direct JMAP checks cover:

- Session discovery, six mailboxes, two messages and their thread, including
  original address decoding and ISO-8601 dates.
- HTTP 401 mapped to authentication-required error `-1013`.
- A malformed method response rejected with error `-1016`.
- Creating, renaming and deleting one synthetic mailbox on the fixture server.

`JmapProbe.swift` calls upstream `JMAPClient` methods directly. The TLS server
extracts the embedded JSON vectors from the pinned upstream SessionTests,
MailboxTests and EmailTests. Only service URLs and email mailbox memberships are
normalized for the local server. It verifies authorization, headers, account ID,
capabilities, call IDs, compound filters and the exact method sequence. Separate
fixture counters confirm all operations. No external mail account is involved.
HiLog records all three mailbox operations with interpolated names redacted.
The emulator was stopped and verified after testing.
The five account-bridge checks described below also pass, with no forbidden
redirect reaching the server and the oversized stream cancelled before 8 MiB.
The main application's five EmailAddress/MIME tests pass with the same native
core. The combined run completed with the emulator stopped on exit.

## Upstream regressions

On the host, 34 upstream test functions pass in the 37-function/18-suite report.
Three provider-dependent parameterized functions have no configured servers and
are skipped by upstream. The HAP fixture tests above separately establish the
native network path; these skips are not live-provider validation.

`host-tests.patch` adds FoundationNetworking imports in two test files and makes
one error-text expectation use the platform's localized description instead of
Apple's fixed English wording. Application logic and other test assertions are
unchanged. `reader-tests.patch` corrects five expected body parts to include the
IDs already present in the unchanged upstream JSON vectors. Previously missing
CodingKeys dropped those IDs during decoding; retaining that bug would prevent
matching text parts to body values. Host logging uses a test-only stderr sink;
HarmonyOS uses HiLog.
The baseline checkout remains pristine and every patch is recorded explicitly.

## Mail application integration

`HarmonyJmapTransport.accountCore` supplies `NativeJmapAccountCore` to the existing
account flow. Its `connect` and `mailboxes` calls cross Node-API onto a worker,
then invoke the original Swift `JMAPClient`. The adapter maps Swift results to
the existing ArkUI data shapes; persistent credentials remain in Harmony's
secure store. Test transports can omit this adapter to exercise the remaining
prototype paths explicitly.

The Swift transport restricts endpoints to HTTPS and the configured origin,
rejects POST redirects, allows at most three same-origin GET redirects, checks
JSON content type and caps streamed responses at 4 MiB. It uses a per-session
URLProtocol with a separate streaming delegate. Task creation is dispatched off
Foundation's shared serial queue to avoid re-entering that queue synchronously.
An earlier rejection retains its error code when late body callbacks arrive.
Each bridge request has a 35-second deadline and cancels its Swift task on expiry.

The native account tests import the production ArkTS and Node-API adapters and
load the same `libThunderbirdCore.so` bytes as the main application. Their TLS
fixture checks a custom discovery path, selection of the second account, mailbox
rights, authentication errors, rejected cross-origin URLs and redirects,
streaming limits, content type, response correlation and POST replay prevention.
The fixture contains only synthetic accounts and mailboxes.

## Message list and reader

`JmapClient.emailPage` and its internal `getEmails` now select the native adapter
in the production app. The Swift bridge calls upstream `Email.QueryMethod`,
`Email.GetMethod`, `MethodGetResponse.decode` and the original `Email` model.
ArkUI retains the existing message data shapes and reader controls.

The explicit source extension retains query state, optional totals and GET
state/notFound. The bridge advances over queried IDs even if some are deleted
before GET, restores query order, rejects changed query state and contradictory
snapshots, and caps pages using the server limit or 50 messages. A short page
without a total remains pageable until an empty page arrives.

The extended `Email` model decodes body values and their truncation/encoding
flags. Body-part IDs now map to the wire field names. The bridge joins only plain
text parts, retains HTML-only status and never substitutes the preview for a
body. Each text body value is limited to 256 KiB, with a 4 MiB response limit.
See [JMAP body values](https://www.rfc-editor.org/rfc/rfc8621.html#section-4.1.4)
and [query state](https://www.rfc-editor.org/rfc/rfc8620.html#section-5.5).

The streaming delegate assembles bounded response data before delivering one
URLProtocol callback: corelibs replaces its response data on each callback.
Reader tests include a valid 120,000-byte Unicode part spanning transport chunks,
an oversized Unicode part, missing body values, invalid dates, duplicate IDs,
deleted messages, pagination and reordered GET responses. These tests use the
production facade and bridges; they do not establish live-provider UI behavior.

## Message changes

The production facade routes `setKeyword`, `archiveEmail` and `undoArchive` to
the Swift client. The bridge passes typed operation arguments and undo data; it
does not accept arbitrary server patches. The original `Mailbox.SetMethod`
encoder is extracted into `ObjectSetMethod<Entity>` and shared by Mailbox and
Email. Original request serialization, transport, response and error models
continue to handle the protocol exchange.

The added Swift workflows check account writability and mailbox permissions,
read a fresh message snapshot and submit only the affected keyword or membership
keys with `ifInState`. Keyword rights must hold in every mailbox containing the
message. Archive uses server roles; undo checks the expected memberships before
restoring Inbox and removes Archive only if this operation added it. Unrelated
keywords and labels remain intact. See [JMAP SET preconditions and responses](https://www.rfc-editor.org/rfc/rfc8620.html#section-5.3)
and [mailbox rights](https://www.rfc-editor.org/rfc/rfc8621.html#section-2).

The SET decoder retains state, rejects malformed result maps and handles method
errors separately from per-message errors. The workflow requires exactly one
acknowledgement for the target message and rejects conflicting or unrelated
create/destroy results. No write is automatically retried; after an uncertain
outcome the existing UI requires Refresh.

Six HAP checks cover explicit seen/flagged values, ordinary and already-archived
undo, unrelated keyword changes, stale memberships, a race before SET, read-only
accounts, denied mailbox rights, request limits, method/per-message errors,
contradictory acknowledgements and a lost response. Fixture counters verify
exact patches, rejected writes and a single applied write when its response is
lost. The earlier four direct JMAP checks still cover mailbox create/update/delete
through the extracted encoder. All 32 isolated checks and the main app's five
EmailAddress/MIME tests pass; the emulator was stopped immediately afterward.

## Draft creation

The production facade snapshots draft input before awaiting credentials. Swift
validates header controls, message references and the 256 KiB UTF-8 body limit,
then uses the selected account's unique Drafts mailbox and the shared SET encoder.
Unfinished addresses remain lossless input: the parsed address initializer would
normalize them too early. No delivery validation or EmailSubmission is invoked.

Successful creation returns acknowledged IDs, size, state and destination.
A valid per-object rejection is definite; a missing, malformed, conflicting or
lost acknowledgement is uncertain. Creation is never automatically retried.
The Node-API input limit is 4 MiB so valid escaped draft bodies can cross the
bridge. The bridge's deadline seals its result before cancelling the task, so a
late completion cannot overwrite an uncertain outcome.

Five HAP tests cover a 150,000-byte Unicode draft and input snapshotting, empty
drafts, unfinished recipients, preflight validation and permissions, definite
rejections, malformed acknowledgements and lost responses. Fixture observations
confirm one creation attempt per save and zero submission calls. See
[the draft workflow and remaining UI work](drafts.md).

OAuth, IMAP/SMTP, connected compose/recovery, HTML/attachment presentation,
offline engine integration and ARM support remain unfinished. These tests
establish native source reuse, not a completed mail application.
