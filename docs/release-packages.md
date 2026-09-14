# Local release packages

Repository: [brunoyuv/DMail](https://github.com/brunoyuv/DMail).
The app's display name remains **D-Mail**.

Run this from a clean, committed checkout with the existing native toolchain
prepared:

```sh
./scripts/test
./scripts/build-release                 # ARM64 devices
./scripts/build-release --arch x86_64   # optional emulator architecture
```

The command produces `dist/D-Mail-VERSION-arm64-v8a-unsigned.zip` and a companion
`.zip.sha256` checksum file. `dist/` is ignored. It does not upload, tag, push,
install, start the emulator or create a GitHub release.

Each ZIP contains:

- A non-debug, **release-mode unsigned HAP** for the selected architecture.
- The matching committed project source archive, including upstream revision/hash
  manifests, dependency source URLs and explicit port patches.
- MPL-2.0 and third-party notices, also embedded in the HAP's raw resources.
- A `release.json` manifest with source revision, version, SDK, architecture and
  hashes of the HAP, source archive and packaged native libraries.
- `SHA256SUMS` covering the files inside the ZIP.

## Signing and Gmail

This is an unsigned package, not a universally installable signed release.
Physical-device installation requires a certificate/profile for the retained
`org.thunderbird.harmony.dev` bundle ID. Local development signing may authorize
only specific registered devices; it is not copied into this package. Keep
private device builds under `scripts/build-device-app`. Do not uninstall an
existing app to work around a signing mismatch.

Public packaging requires Gmail browser sign-in to remain disabled. It explicitly
rebuilds the OAuth adapter with a nil local Google registration, even when an
ignored developer credential file exists. It scans HAP members for private keys
and common Google secret/token patterns and checks release metadata and ELF
architecture before exporting anything to `dist/`.

A private development build's saved Google OAuth account may need its original
registration configuration to refresh. The public package does not promise
OAuth-refresh compatibility with those builds. It does not migrate or delete
saved accounts. Gmail app-password setup remains the default. For your own OAuth
registration, follow the README and use the ordinary build scripts; public
packaging deliberately refuses the browser-login opt-in.

## Build prerequisites and isolation

The release builder uses the pinned CLI 26/SDK 26 and API 22 Swift runtime described
in [environment setup](environment.md) and the [runtime notes](../port/swift-runtime/README.md).
A clean checkout alone is insufficient: install the documented SDKs and Swift
compiler, stage the pinned Thunderbird source, and build the architecture's
native dependency graph first. The script reports a missing FoundationNetworking
SDK before attempting an incomplete build. The host test dependencies must also
be installed as described in the README.

Release staging uses only tracked HarmonyOS files and writes to dedicated ignored
`.tools/release-app*` directories. It excludes test modules and local signing,
rebuilds the Swift core, and enables native symbol stripping in Hvigor. Swift
runtime/dependency artifacts retain the existing port's compilation settings;
`release` describes the verified HarmonyOS application build mode.

The existing production/device HAPs, staged libraries and signing profile are
not overwritten. Native compiler caches are shared, so do not run development
native builders concurrently. A lock serializes release builds. Source changes
during the build abort export; the source archive always identifies the exact
committed project revision. `.tools/release-app*` are generated directories and
are replaced on the next release build.

Before any public upload, inspect the ZIP and manifest and validate the intended
signing and device target. Building a release-mode HAP does not establish native
runtime or live-provider behavior on a device.
