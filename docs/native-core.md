# Native Thunderbird core: first HAP integration

Verified on 13 September 2026 using the x86-64 HarmonyOS 6.0.2 emulator.

The original `Core/Sources/EmailAddress/EmailAddress.swift` and `String.swift`
from Thunderbird iOS revision `61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf` now compile
**without source patches** for `x86_64-unknown-linux-ohos`. The resulting
`libThunderbirdCore.so` dynamically loads Swift and Foundation libraries built
against Huawei's native SDK. No static Linux SDK is used in this build.

The emulator returned `THUNDERBIRD_NATIVE_EMAIL_ADDRESS_OK`. The C test checks:

- Unicode display names and whitespace trimming.
- The parsed address, host, local part and display description.
- Valid/invalid address decisions and group equality independent of order/label.
- A C validation API with valid text, invalid text and a null pointer.

The validation API in `port/swift-bridge/EmailAddressBridge.swift` converts UTF-8
input and calls the original `EmailAddress.isEmailAddress`. It contains no
replacement address parser. Its signature is:

```c
int32_t thunderbird_email_address_validate(const char *input);
```

The separate development-process test runs under `/data/local/tmp/thunderbird-native-core`.
The app now also packages a production `libThunderbirdCore.so` without that probe's
entry point. `libthunderbird.so` is a narrow Node-API adapter. The HAP contains all
22 native libraries, including Swift, FoundationNetworking and their dependencies. The
original upstream checkout remains pristine.

The two EmailAddress HAP tests pass on the emulator: validation through Node-API (including Unicode,
invalid input and embedded NUL rejection), and the actual EntryAbility composer
flow. The latter enters an invalid recipient, blurs the field, observes the
HarmonyOS TextInput error, then replaces it with a valid address and verifies
that the error clears. [The screen capture](screenshots/native-recipient.png)
shows the native validation error. Neither test sends mail.

All 15 original MIME source files now also run inside the HAP without patches.
`port/swift-bridge/MimeBridge.swift` calls upstream header encoding/decoding,
`Body`, `Part.parts` and `Body.rawValue`. Node-API schedules MIME work on worker
threads and the typed ArkTS adapter at `harmony/entry/src/main/ets/core/Mime.ets`
returns promises. It maps upstream values across the language boundary; it
contains no replacement MIME parser.

Three additional tests pass: the original encoded-header vectors plus 20 concurrent
worker calls; all 13 unchanged upstream message fixtures, matching the upstream
serialized byte counts and selected part types; and malformed-input rejection
followed by a successful request. The fixtures are staged only in the test HAP.
Their hashes and the native result are recorded in
`port/swift-probe/native-mime-result.json`.

The bridge currently accepts ASCII MIME transfer representations up to 16 MiB,
with at most 32 levels and 4096 parts. `encodedPayloadBase64` transports the original
`Part.data` bytes before transfer decoding; it is not decoded message text.
HTML rendering, attachment presentation and the reader's native mail-engine path
remain unfinished. The [original JMAP client](native-jmap.md) now handles account
discovery, mailbox loading, message lists and plain-text reading in the app,
compiled into this same core. Read/unread, stars and archive/undo also use Swift workflows. The draft-creation backend also runs in Swift; connected compose and ARM
devices remain unfinished.
This is not a completed port.

## Reproduce

After the existing Huawei and Swift compiler setup:

```sh
./scripts/build-swift-foundation-compat
./scripts/test-native-email build
./scripts/test-native-app build
./scripts/test-native-app device
```

The preparation step verifies the pinned checkout and source hashes. Native
artifacts, logs and `provenance.json` are under `.tools/swift-probe/native-email/`.
That manifest records the target triple, zero Thunderbird source patches, both
source hashes and hashes of the transferred payload. The test requires the
success marker, since HDC can report shell success after a remote program fails.

The app test prepares no build work while the emulator is running. Its `device`
mode starts the emulator, installs both HAPs normally, runs all five tests, restores
the prior UiTest setting and stops the emulator on exit, including test failures.
Results are recorded in `port/swift-probe/native-app-result.json`; local full logs
are `.tools/native-app-device.log` and `.tools/native-draft-device-session.log`.

## Platform adaptations

EmailAddress and MIME remain unchanged. JMAP's explicit source adaptations are
documented in [native-jmap.md](native-jmap.md). Runtime/dependency patches are recorded in
`port/swift-runtime/`. The full Foundation adaptation adds native C++ linking,
musl feature flags and the supplemental `fts` include path. It excludes the
unsupported Float80 initializer and selects Foundation's existing `ENOSYS`
fallback for a spawn-directory action absent from Huawei's SDK. Foundation's
existing caller handles that fallback; process spawning has not been tested.

Swift Dispatch uses one canonical installed C module map to avoid duplicate
module definitions. The `fts` header similarly has one owner, `CFTS`, re-exported
through the Musl binding.

Foundation and FoundationXML build. The separate [networking dependency build](native-networking.md)
now passes six isolated HAP tests, including TLS verification and cancellation.
User CA policy remains unfinished; account discovery, mailbox loading and message reading now use this transport.
Command-line Foundation tools remain disabled. The native XML
dependency is libxml2 2.14.6, verified against the publisher's SHA-256 file at
GNOME. The dependency manifest pins that archive; it is a bootstrap version,
not a claim that all production dependency maintenance is complete.

## Next gate

Extend the verified native networking path to the actual upstream mail engines.
Retire the corresponding prototype logic as each original module becomes usable
through the app's native interface. Preserve upstream tests and fixture behavior,
and verify real networking, account handling and device ABI support before
claiming the full port is complete.
