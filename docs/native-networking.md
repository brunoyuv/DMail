# Native Swift networking on HarmonyOS

On 13 September 2026, OpenSSL, curl and Swift FoundationNetworking built for
`x86_64-unknown-linux-ohos` using Huawei's SDK. These are native libraries;
host Linux libraries were not substituted. Six networking tests, four original JMAP tests and five production account-bridge tests and six reader-bridge tests, six message-change tests and five draft tests now pass inside an isolated
HarmonyOS HAP using the same core libraries as the mail application.

The selected sources are [OpenSSL 3.5.8 from its LTS branch](https://openssl-library.org/source/)
and [curl 8.22.0](https://curl.se/download.html). OpenSSL's archive matches the
publisher's SHA-256. curl's signature verifies against the fingerprint published
on [curl's verification page](https://curl.se/docs/verify.html).
`port/swift-runtime/network-dependencies.json` pins both archives and their hashes.

```sh
./scripts/prepare-native-network
./scripts/build-native-tls
./scripts/build-native-curl
./scripts/build-swift-networking
./scripts/test-native-network build  # Emulator off
./scripts/test-native-network device # Starts, tests, uninstalls test app, stops
```

The Foundation prerequisite is `scripts/build-swift-foundation-compat`.
Installed outputs are under `.tools/swift-ohos-sdk/`: `lib/libssl.so.3`,
`lib/libcrypto.so.3`, `lib/libcurl.so.4` and
`lib/swift/musl/libFoundationNetworking.so`.

OpenSSL uses its x86-64 assembly configuration with the OHOS compiler, headers
and linker. Loadable providers, legacy engines and its optional async-job
interface are disabled for this initial build. FoundationNetworking retains its
asynchronous URLSession implementation. curl uses OpenSSL and the threaded DNS
resolver; HTTP/2 and optional compression/IDN libraries are not enabled yet.

`port/swift-runtime/corelibs-harmonyos.patch` selects the native C++ linker,
configures the networking C shim and propagates URL policy failures as errors.
Foundation's main bundle lookup uses the HarmonyOS application bundle mount
inside a HAP; the system launcher is outside that sandbox. Apple bundle metadata
and resource conventions are not translated by this change.

An HTTPS teardown abort reproduced after successful requests. The patch adapts
[Wes Tarle's upstream Swift cleanup fix](https://github.com/swiftlang/swift-corelibs-foundation/pull/5491)
(commit `13899dd72ac76d3129272567f678cfaa74a2cec3`, still an open proposal when
inspected). The callback owner stays alive on its serial queue while curl closes
connections. An additional closing flag prevents queued timer/socket actions
from using the released curl handle. All eight patched files reproduce from the
pinned Swift release archive, with explicit forward/reverse patch checks.

Repeated short-lived account sessions also exposed a success/cancellation race: URLSession resumed the same checked continuation twice. The patch atomically claims task completion on the task queue before dispatching either callback. Twelve sequential reader requests now exercise completion followed by session cancellation. This regression check passes alongside the existing cancellation and TLS teardown checks.

## Platform trust

`port/swift-runtime/HarmonyTrust.c` consults HarmonyOS's NetStack APIs for each
selected URL. It enforces cleartext policy, app-configured trust anchors and
public-key pins, and uses `/etc/security/certificates` for system roots. Peer and
hostname verification remain enabled. The platform API can return rehashed
certificate directories; the adapter also handles the PEM form described by the
SDK header. See the [platform API implementation](https://github.com/openharmony/communication_netstack/blob/master/interfaces/kits/c/net_ssl/src/net_ssl_c.cpp)
and [network security configuration documentation](https://github.com/openharmony/docs/blob/master/en/application-dev/network/http-request.md).

User-installed CA policy remains unimplemented. The test app explicitly disables
user CAs and supplies its own temporary CA through its network profile; no
certificate is installed device-wide. Pinning and redirects are wired but have
not been exercised by these tests. This is not yet full system trust-policy parity.

## Measured result

On the x86-64 HarmonyOS 6.0.2/API 22 emulator, all six tests passed:

- HTTP returned the expected body.
- App-trusted HTTPS returned the expected body across 21 separate URLSessions,
  exercising the formerly failing TLS teardown.
- An untrusted issuer and a wrong hostname were rejected before HTTP reached
  either TLS fixture. The fixture observed both attempted connections.
- Cancelling a Swift Task returned error `-999`; the server observed the disconnect.
- The profile's blocked cleartext hostname never reached the HTTP fixture.
- `https://example.com/` succeeded using system roots.

The combined 32-test suite took 7.013 seconds after installation. The runner removed the test app
and forwards, stopped the local fixture and verified the emulator was stopped.
The emulator is kept off during builds and never left idle after tests.
`port/swift-probe/native-networking-result.json` records HAP/library hashes,
commands, test scope and fixture observations. Detailed local logs are under
`.tools/network-test-*.log`.

The original JMAP source now [runs against the local TLS fixture](native-jmap.md),
with four direct JMAP tests, five account-bridge tests, six reader-bridge tests, six message-change tests and five draft tests. The mail application
uses this bridge for account discovery, mailbox loading, plain-text reading, flags, archive/undo and draft creation. The connected composer is still unfinished. These tests do not
establish mail functionality, ARM support, cookie/cache persistence or complete
URLSession compatibility.
