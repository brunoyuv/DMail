# HarmonyOS development environment

Installed on Linux x86_64, 13 September 2026; HAP build configuration updated to CLI 26 on 14 September 2026. Tool binaries and downloads are local development assets, excluded from Git.

| Component | Version | Location |
| --- | --- | --- |
| Node.js | 22.23.2 | `.tools/runtime/node_modules/node/bin/node` |
| Huawei DevEco CLI | 1.3.0-stable | `.tools/deveco/node_modules/.bin/devecocli` |
| Command Line Tools / HAP build SDK and emulator | 26.0.0.821 / SDK 26.0.0.105, API 26 | `.tools/deveco-26/command-line-tools/` |
| Hvigor / bundled build Node.js | 6.26.4 / 24.14.1 | `.tools/deveco-26/command-line-tools/` |
| Pinned Swift native SDK | 6.0.2.670 / SDK 6.0.2.130, API 22 | `.tools/command-line-tools/` |
| TypeScript test compiler | 5.9.3 | `.tools/test/node_modules/typescript/` |
| Swift host compiler | 6.2.3 | `.tools/swift/usr/bin/` |
| Swift static Linux SDK (experimental compatibility probe) | 6.2.3 / 0.0.1 | `.tools/swift-sdk/` |

Swift setup and the distinction between the static Linux probe and a native HarmonyOS runtime are documented in [Swift reuse probe](swift-probe.md). Native Swift runtimes are built separately at `.tools/swift-ohos-sdk/` (x86-64) and `.tools/swift-ohos-sdk-aarch64/` (ARM). Both package the combined original mail core; the ARM HAP is signed and installed on the Pura X. See [physical-device testing](device-testing.md) for verification limits and rebuild instructions.

The full DevEco Studio desktop IDE is not offered for Linux. Huawei's official Linux Command Line Tools provide the native compiler, package tools, debugger and, starting with 26.0.0, emulator. The DevEco CLI uses the 26.0.0 bundle. HAP build scripts also select that bundle through `scripts/harmony-build-env`, with its Node.js and SDK and a separate `.tools/hvigor-home-26/` cache. Host tests continue to use the separately pinned Node.js 22 runtime.

The production build profile explicitly sets `compileSdkVersion` to `26.0.0` while retaining `targetSdkVersion` and `compatibleSdkVersion` at `6.0.2(22)`. This enables the current compiler and API declarations while preserving the existing runtime target and minimum installation version. APIs introduced after 22 still need runtime availability checks; changing the compiler does not grant newer operating-system capabilities or background-task permissions.

Swift, its dependencies, and `libThunderbirdCore.so` continue to use the API 22 native sysroot pinned in the native build scripts. HAP builds compile the small N-API wrapper using SDK 26 and import those existing libraries. Both installed native toolchains report Clang 15.0.4 and the same ABI family, but release validation must still check the resulting HAP metadata/library hashes and run the prepared synthetic fixture on the API 22 emulator. See the current release validation record for completed build and device checks.

Release 0.1.11 passed this compatibility check: production x86, signed ARM and isolated fixture HAPs built with SDK 26.0.0.105; metadata retained minimum/target API 22 and imported Swift hashes matched. Synthetic IMAP and persisted OS-badge/notification-lock gates passed on the API 22 emulator. The same signed update was installed in place on both Pura X and MatePad without opening production. See [release 0.1.11](release-0.1.11.md).

Device staging merges local signing into the current production build profile. Isolated IMAP fixture staging likewise copies the current compiler/target/minimum settings while preserving its local signing. Previously generated `.hvigor` and native build outputs are not evidence that a build used CLI 26; check the new build log and HAP metadata after rebuilding.

## Recreate

1. Sign into the [official download center](https://developer.huawei.com/consumer/cn/download/command-line-tools-for-hmos).
2. Download the Linux x86_64 bundles named `commandline-tools-linux-x64-6.0.2.670.zip` and `commandline-tools-linux-x64-26.0.0.821.zip` into `.tools/`.
3. Compare the files against Huawei's published integrity information, then run `./scripts/setup`.
4. Run `./scripts/doctor`, `./scripts/test`, and `./scripts/build`.

These are the SHA-256 hashes calculated for the downloaded archives in this workspace. They are recorded for reproducibility; the browser's checksum-copy control did not expose the publisher's value to automation, so no independent publisher-hash comparison is claimed.

```text
fed05c5a416427537217098a39988ef42e1c215a0153611729b76649b2c3e4ef  commandline-tools-linux-x64-6.0.2.670.zip
58da7359019e9360a8bb82da0cd1d3b3b26fedc338379f257849f2162e3ac1fc  commandline-tools-linux-x64-26.0.0.821.zip
```

Both ZIP archives extracted successfully. Authenticated download URLs and account information are not stored in tracked files.

## Emulator

The emulator can freeze this host's desktop. Keep it stopped during development and builds; start it only for a prepared device test. Stop `ThunderbirdPhone` immediately after each test session, including failed or interrupted sessions, and verify that its status is `stopped`. Do not leave it running idle between tests.

`./scripts/test-native-app build` prepares the HAPs while the emulator is off. `./scripts/test-native-app device` uses `scripts/with-test-emulator` to launch the device for the prepared tests, bound test execution to three minutes, and stop it on exit. That wrapper can also run other prepared test commands. It reports the emulator's final status; shutdown errors are failures requiring immediate attention.

```sh
./scripts/deveco emulator stop ThunderbirdPhone
./scripts/deveco emulator list
```

The user approved the CLI emulator license/privacy agreements and the additional native emulator agreements for this setup. They were accepted, the image was installed, and `ThunderbirdPhone` launched successfully. On a fresh host, review the agreements with `./scripts/deveco emulator license view` and accept them before downloading images; the native launcher may present additional agreements.

```sh
./scripts/deveco emulator image list --device-type phone --all
./scripts/deveco emulator image download --device-type phone --os-version 'HarmonyOS 6.0.2(22)'
./scripts/deveco emulator create ThunderbirdPhone --device-type phone --os-version 'HarmonyOS 6.0.2(22)'
./scripts/deveco emulator start ThunderbirdPhone
```

The emulator uses Huawei's default image directory under `~/Library/Huawei/Sdk/system-image/`. Linux execution requires KVM and graphics-device access. Sandboxed commands may not see `/dev/kvm` even when the host has it. Do not disable security checks to work around that; launch through an authorized host execution context.

This workspace's instance runs headlessly with the native launcher:

```sh
.tools/deveco-26/command-line-tools/emulator/Emulator -start ThunderbirdPhone -noWindow
```

The installed image is HarmonyOS 6.0.2 (API 22), phone software 6.0.0.130, with a Pura 90 Pro profile (1256 × 2760, density 560, 4 GB RAM). HDC connects at `127.0.0.1:5555`. The emulator accepts the unsigned development HAP normally; no signature-verification bypass was used.

```sh
.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555 install harmony/entry/build/default/outputs/default/entry-default-unsigned.hap
.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/hdc -t 127.0.0.1:5555 shell aa start -a EntryAbility -b org.thunderbird.harmony.dev
./scripts/deveco ui screenshot --device 127.0.0.1:5555 --path ../docs/screenshots/inbox.png
```

Huawei's optional keyboard service displayed a separate consent flow, which was dismissed. Its service agreements were not accepted. Native composer input, blur validation and error recovery now pass UiTest checks; see [native core integration](native-core.md).

The HAP produced by `./scripts/build` is unsigned. Installing on a physical device requires a developer signing profile for `org.thunderbird.harmony.dev`. Never commit certificates, private keys, passwords or provisioning profiles.

## References

- [Huawei Command Line Tools](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get)
- [DevEco CLI](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-deveco-cli)
- [Linux emulator](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-emulator)
