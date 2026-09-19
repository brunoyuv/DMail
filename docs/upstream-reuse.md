# Upstream reuse: architecture correction

On 13 September 2026 the user identified that the current work was a rewrite rather than the requested Thunderbird port. That assessment is correct: `harmony/` compiles independently written ArkTS models, JMAP operations, storage and screens. At that point, the original Swift source was only an ignored reference checkout. Prototype test results establish prototype behavior; they do not establish a port of the upstream application.

## Required direction

Use upstream Thunderbird source as the core of the deliverable, retain its module boundaries and tests where possible, and make platform adaptations explicit and reviewable. An ArkUI presentation layer can follow HarmonyOS's system design, but it must call the reused core rather than become a second implementation of its mail protocols and domain model.

Before implementing more connected-mail features, demonstrate that an original upstream module can be compiled for the actual HarmonyOS application ABI, packaged in the HAP and called from ArkTS through a native bridge. A host Linux build alone is insufficient. A small module demonstration is a feasibility gate, not completion of the port; the Account, MIME, JMAP, IMAP and SMTP paths still need a module-by-module reuse plan and verification.

## Evidence from the checked-out source

Reference revision: `61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf`.

`Core/Package.swift` uses Swift tools version 6.2. Its libraries include Account, Autoconfiguration, Core, EmailAddress, IMAP, JMAP, MIME and SMTP. Its dependency declarations currently track upstream branches; a reproducible port also needs resolved dependency revisions.

| Upstream module | Source files | Observed dependencies requiring assessment |
| --- | ---: | --- |
| EmailAddress | 2 | Foundation; first small reuse candidate |
| MIME | 15 | Foundation; next candidate with upstream fixture tests |
| JMAP | 23 | Foundation, OSLog, UniformTypeIdentifiers; URLSession platform support |
| IMAP | 43 | SwiftNIO/IMAP/SSL, Foundation and OSLog |
| SMTP | 11 | SwiftNIO/SSL/Extras/TransportServices, Network and OSLog |
| Autoconfiguration | 18 | AsyncDNSResolver, CryptoKit, dnssd and Foundation |
| Account | 22 | The above core modules, Foundation and AuthenticationServices |

These are a source-import inventory, not proven compile failures. Conditional imports and available alternative implementations must be checked before deciding which adapters are necessary. The app's SwiftUI/BoltUI layer also requires separate platform treatment.

Swift 6.2.3 is installed locally. Sixty unchanged upstream EmailAddress/MIME tests pass on the host. The experimental native runtime and Foundation libraries now compile unchanged EmailAddress source for HarmonyOS, and its shared-library C API passes on the emulator. The original module now also passes Node-API and composer UI tests inside the HAP. The complete mail dependency graph remains unproven. See the [measured probe results and commands](swift-probe.md).

## Next proof and acceptance criteria

The experimental Swift Core runtime now builds against the native OHOS SDK and
passes a small C/Swift emulator smoke test. Its platform patches are recorded in
[`port/swift-runtime`](../port/swift-runtime/README.md). This advances the first
criterion below. Native concurrency and FoundationEssentials also pass emulator
smoke checks. The full Foundation compatibility library now builds, and original
EmailAddress source passes a native shared-library emulator probe and two HAP
integration tests, including actual composer validation through ArkUI.
See the [native core evidence](native-core.md); no Thunderbird source patches
were required for that module.

1. Establish a Swift toolchain and target runtime compatible with the emulator and eventual device ABI, or document specific toolchain failures with reproducible commands. Do not substitute an Android or host-Linux binary for a HarmonyOS result.
2. Build the original EmailAddress module and its dependencies with traceable, minimal platform patches; preserve an exact upstream baseline.
3. Call the resulting implementation inside the HarmonyOS HAP through a narrow native interface and verify upstream behavior on the emulator.
4. Extend this path to MIME and the actual mail engines, with a traceable inventory of reused files, patches, platform adapters and remaining gaps.
5. Connect the native UI to that core and retire duplicate prototype logic as each path is replaced.

The existing prototype and installed environment remain available while this integration work proceeds. A HAP using EmailAddress is demonstrated; a completed port is not. All 15 original MIME source files now run unchanged through the native HAP bridge, with 13 upstream fixtures and header checks passing. Connecting the reader to the original mail engines remains the next work.

Native FoundationNetworking now passes six isolated HAP tests, including TLS
trust/rejection, repeated teardown and cancellation. The native library built from all 23 original JMAP source
files also [runs in a HarmonyOS HAP](native-jmap.md). Eleven files have explicit
patches for imports, account context, response correlation, reading and message changes;
12 remain unchanged.
Four direct JMAP tests, twenty-two production account/reader/change/draft-bridge tests and 34 upstream host
test functions pass; three provider-dependent functions are skipped. The app now
uses the original JMAP client for account discovery, mailbox loading, message
lists and plain-text reading. Read/unread, stars and archive/undo also run in Swift. Draft creation now uses the shared Swift SET encoder. The duplicate ArkTS protocol engine and Remote Communication Kit transport now live only under the test source set. The shipping client requires Swift and has no HTTP fallback. Connected compose and durable recovery remain unfinished.

The shipping core also includes all 43 original IMAP files, 31 unchanged,
with pinned SwiftNIO/IMAP/SSL dependencies and explicit platform/lifecycle patches.
Its module objects are linked once alongside EmailAddress, MIME and JMAP; no
standalone duplicate or diagnostic is shipped. Three original Account body files
are also compiled into the IMAP account adapter (two unchanged). Across these
modules, 86 original source files are compiled, 62 unchanged. Twenty-four native
IMAP/account/body/UI tests, 32 networking/JMAP tests and five mail-app core tests
pass against the same shared-library bytes. Fifteen historical prototype/UI
regressions also pass. The IMAP account screen now saves credentials, lists
mailboxes, pages messages reads their MIME bodies, and updates read/unread and stars using this Swift core. Email identity and authentication login are separate fields.
This reading and flag-update milestone is verified with synthetic servers; real providers,
remaining Account features and ARM device builds still need verification.

## SMTP and connected replies

All eleven original SMTP files are now staged and compiled with the shared Swift
core. Server, ConnectionSecurity and ByteHandler remain unchanged; the recorded
patch adapts transport and adds validated sending and reply headers. The original
IMAP Message now also retains top-level References for replies. Together the
shipping modules contain 97 original files, 64 unchanged. The earlier counts and
test evidence above describe their respective historical stages.

## MIME compatibility and HTML images

The current shipping source inventory remains 97 upstream files; 62 are unchanged.
MIME Body and Part now have recorded byte-preserving parser adaptations. The
original Account body decoder also maps legacy charsets and keeps readable parts
when a sibling fails. See [MIME port details](../port/swift-mime/README.md). The
separate 13-file Autoconfiguration stage is not included in these shipping counts.

The local 1.0.4 detailed-download diagnostic follow-up adds the explicit
`port/swift-imap/download-diagnostics.patch` after the existing protocol patches.
It observes safe command/response/literal categories before generic error mapping;
original pinned source files and hashes remain unchanged. Additional bounded
instrumentation lives in the existing MIME parser and IMAP account/body port
adapters. See [download diagnostics](download-diagnostics.md).

The subsequent singlepart correction is confined to the existing
`port/swift-imap/ReadableBody.swift` adaptation: root bodies and attachments use
the original client's HEADER fetch, while multipart child MIME requests remain
unchanged. Original pinned sources, hashes and attribution are preserved. See
[the synthetic reproduction](outlook-singlepart-header-fix.md).

Foreground page/body reads also use the existing port-owned SyncReadSessionPool
with original IMAPClient operations. The follow-up discards sockets closed by
optional command timeouts and adds safe session lifecycle trace reasons; it does
not replace upstream protocol/MIME clients. See [read-session follow-up](imap-read-session-follow-up.md).

The connection greeting correction adds `port/swift-imap/initial-greeting.patch`
and the port-owned `InitialGreeting.swift` handler after the existing patches.
The original Swift client's verified TLS pipeline now waits for the greeting
before CAPABILITY. Pinned upstream files, hashes and attribution are unchanged.
See [the greeting reproduction and validation](imap-greeting-fix.md).

The MIME fetch batching follow-up changes the existing local
`port/swift-imap/ReadableBody.swift` adaptation. It groups at most two small,
already-selected MIME parts into one original-client UID FETCH, preserving
root/child header selection, UID checks, per-part limits and partial siblings.
No pinned upstream source/hash or Swift protocol implementation is replaced.
See [batching validation](mime-fetch-batching.md).
