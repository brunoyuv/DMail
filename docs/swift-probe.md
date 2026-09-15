# Upstream Swift runtime probe

Verified 13 September 2026. This follows the [architecture correction](upstream-reuse.md): reuse original Thunderbird code, with explicit platform adapters, instead of extending an independent mail implementation.

## Results

| Check | Observed result | What it proves |
| --- | --- | --- |
| Official Swift 6.2.3 toolchain | Installed locally; archive signature verified | A working host compiler is available |
| Original EmailAddress and MIME source/tests | 53 files staged with no source patches; hashes match the pinned checkout | Source reuse is traceable |
| Original host tests | 60 tests in 17 suites pass | These modules work unchanged on this Linux host |
| Native HarmonyOS compile | Fails to load the standard library for `x86_64-unknown-linux-ohos` | The installed compiler alone is insufficient for the native app target |
| Native compile with Linux SDK module search paths | Rejects `_Concurrency`: available module targets `x86_64-swift-linux-musl` | Supplying the Linux SDK search path does not supply a matching HarmonyOS runtime |
| Static Linux build | Original modules build using the matching musl SDK | The SDK can compile these modules into a Linux executable |
| Static executable on HarmonyOS emulator | Unicode address parsing and MIME round-trip checks pass | Those specific upstream operations execute on the emulator through this static runtime |
| Experimental native Swift Core runtime | Builds with explicit platform patches; C/Swift smoke test passes on the emulator using the new shared library | Basic Swift operations execute against the native OHOS ABI |
| Native concurrency and dispatch | Task groups, actor updates, timers and cancellation pass on the emulator | Those asynchronous runtime paths execute using the OHOS libraries |
| Musl binding, regex, synchronization, ICU and file-tree traversal | Native builds pass; regex, mutex, process-argument and traversal smoke checks pass on the emulator | Those platform operations work in the tested development process |
| FoundationEssentials and FoundationInternationalization | Both native libraries build; Essentials JSON, URL and directory-listing checks pass on the emulator | The modern Foundation components run for those tested operations |
| Full Foundation and FoundationXML | Native libraries build; original EmailAddress calls through Foundation pass on the emulator | Foundation supports the tested upstream operations; XML-specific behavior remains untested |
| Original EmailAddress in native shared library | Two unchanged upstream files compile; C API checks pass on the emulator | Actual source reuse works against the native SDK |
| Native HAP library / ArkTS bridge | HAP contains 18 native libraries; Node-API and actual composer UI tests pass | Original EmailAddress and MIME run in the x86-64 app process; full mail-core integration remains unfinished |
| Original MIME native module | All 15 unchanged source files run through an asynchronous HAP bridge; 13 fixtures and encoded-header checks pass | Original MIME parsing/serialization runs in the app process; the reader and mail engines remain unfinished |

The static executable is an explicit compatibility experiment. Its target is Linux musl, not HarmonyOS. It ran from `/data/local/tmp` on the x86-64 HarmonyOS 6.0.2 emulator, without changing security settings. It is not included in the HAP. No ARM device runtime, production app sandbox, mail network engine or complete Thunderbird core is covered by this result.

The executable prints these markers only after checking the original implementations' results:

```text
UPSTREAM_EMAIL_ADDRESS_OK
Thunderbird 鸿蒙 <reader@example.com>
UPSTREAM_MIME_ROUNDTRIP_OK
```

## Reproduce

The reference checkout must be at revision `61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf`, with the selected modules and tests unmodified. The repository URL is `https://github.com/thunderbird/thunderbird-ios`; place its checkout at `upstream/thunderbird-ios/`.

```sh
./scripts/setup-swift
./scripts/swift-probe host
./scripts/swift-probe static-linux
./scripts/swift-probe ohos
```

The last command currently fails with a missing standard library. That failure is retained, rather than changing the target or reporting the static Linux result as a native build. The first two probe modes use an isolated Swift package containing upstream EmailAddress and MIME source and tests, plus a small diagnostic entry point. They do not build the complete upstream Core package or its remote dependencies.

Source provenance: `port/swift-probe/upstream-files.json`. The preparation script verifies the revision, checks for source modifications, and checks each copied file against the recorded hash. Build/cache files stay in `.tools/swift-probe/`.

The wrapper output at `.tools/swift-probe/build-static-linux/x86_64-swift-linux-musl/debug/upstream-probe` was also transferred and verified on the emulator. To reproduce on the already running emulator:

```sh
.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555 file send .tools/swift-probe/build-static-linux/x86_64-swift-linux-musl/debug/upstream-probe /data/local/tmp/thunderbird-upstream-probe-static
.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555 shell chmod 755 /data/local/tmp/thunderbird-upstream-probe-static
.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555 shell /data/local/tmp/thunderbird-upstream-probe-static
```

## Toolchain provenance

Compiler: [Swift 6.2.3 Ubuntu 24.04 release](https://www.swift.org/install/linux/ubuntu/24_04/), downloaded from `download.swift.org`. Verified against its detached signature with the release key fetched from Swift's official public-key bundle. Signing fingerprint: `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F` (Swift 6.x Release Signing Key). The setup script pins the verified archive's SHA-256:

```text
3e0b8eaf9210131a1756e6a1a9e9103bac83609a0ae604d6f2e791053f98f115
```

Static SDK: `swift-6.2.3-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz`, downloaded from `download.swift.org`. Its computed SHA-256 matches the [published 6.2.3 installation command](https://github.com/swiftlang/swift-foundation/issues/1676):

```text
f30ec724d824ef43b5546e02ca06a8682dafab4b26a99fbb0e858c347e507a2c
```

Swift's [static SDK documentation](https://www.swift.org/documentation/articles/static-linux-getting-started.html) explicitly excludes dynamic linking. Its successful executable run is not evidence that a library built with the SDK can be loaded through HarmonyOS Node-API.

## Next engineering gate

The first native Core runtime now builds from Swift 6.2.3 source, with [reviewable platform patches and a smoke test](../port/swift-runtime/README.md). Reproduce using `./scripts/build-swift-runtime` followed by `./scripts/test-swift-runtime device`. Unlike the earlier static experiment, this uses the Huawei native SDK and OHOS target throughout. The ordinary `swift-probe ohos` command above still demonstrates the original compiler installation's missing runtime; the experimental runtime is installed separately and explicitly selected by its own test script.

The full `swift-corelibs-foundation` compatibility module now builds against the native ABI. Original EmailAddress code passes a C API probe on the emulator; see the [native core record](native-core.md). The narrow Node-API bridge and actual composer UI now pass two tests inside the HAP. Concurrency and FoundationEssentials also pass native emulator smoke checks. The missing file-tree traversal (`fts`) API is supplied by the existing musl-fts implementation compiled against Huawei's SDK, and Swift's command-line support is enabled.

A temporary attempt to compile EmailAddress by changing only its import to FoundationEssentials failed: `String.trimmingCharacters(in:)` is provided by the full Foundation layer. That adaptation was discarded. Building the actual Foundation dependency resolved it, and `port/swift-probe/native-email-probe.*` now passes with unchanged upstream files.

Reproduce the completed native component work with `./scripts/build-swift-foundation`, then `./scripts/test-swift-platform device` and `./scripts/test-swift-concurrency device`. The Foundation build script currently builds **FoundationEssentials and FoundationInternationalization**, not the full Foundation/Networking/XML compatibility modules. The source versions are pinned in `port/swift-runtime/foundation-dependencies.json`; the runtime and Foundation CMake changes are separate reviewable patches. These tests run in the emulator's development temporary directory, not inside the app sandbox.

After that gate, bring across the original JMAP and mail engines with explicit, minimal platform patches and their tests. Host test success or a diagnostic executable is not completion of the requested port.
