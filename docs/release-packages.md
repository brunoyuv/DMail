# Local release packages

Repository: [brunoyuv/DMail](https://github.com/brunoyuv/DMail).
The app's display name remains **D-Mail**.

Run this from a clean, committed checkout with the existing native toolchain
prepared:

```sh
./scripts/test
./scripts/build-release                 # ARM64 devices
./scripts/build-release --arch x86_64   # optional emulator architecture
./scripts/build-release --appgallery   # registered store identity, unsigned APP
```

The command produces `dist/D-Mail-VERSION-arm64-v8a-unsigned.zip` and a companion
`.zip.sha256` checksum file. `dist/` is ignored. It does not upload, tag, push,
install, start the emulator or create a GitHub release.

Each ZIP contains:

- A non-debug, **release-mode unsigned HAP** for the selected architecture.
- An unsigned APP containing the verified HAP. A copy of the APP and its SHA-256
  checksum is also exported directly to `dist/`.
- The matching committed project source archive, including upstream revision/hash
  manifests, dependency source URLs and explicit port patches.
- MPL-2.0 and third-party notices, also embedded in the HAP's raw resources.
- A `release.json` manifest with source revision, version, SDK, architecture and
  hashes of the HAP, source archive and packaged native libraries.
- `SHA256SUMS` covering the files inside the ZIP.

## Signing and Gmail

### AppGallery identity and release signing

The registered AppGallery bundle ID is **`some.DMail.hamorny`**, preserving the
owner's exact spelling and case. `packaging/appgallery.json` records it;
`--appgallery` applies it only in the generated ARM64 release project. The
ordinary development identity stays `org.thunderbird.harmony.dev` for existing
test installations. These identities are separate apps with separate saved data.
Both display **D-Mail**. The current version is **1.0.5**, code **1000005**.

Run `./scripts/build-release --appgallery --no-zip` to produce
`dist/D-Mail-1.0.5-arm64-v8a-appgallery-unsigned.app` and a companion directory
with source, licenses and checksums. The builder verifies the bundle ID and
version in both APP and HAP, and checks that the APP embeds the inspected HAP.
The store listing icon is `docs/images/d-mail-icon.png` (1024 × 1024).
The [six store screenshots](appgallery-screenshots.md) are available separately,
with three standard-phone and three tablet images.

The unsigned builder output remains a pre-signing candidate. The owner supplied
a Huawei release certificate and matching `app_gallery` release profile on
2026-09-14. The local release key, CSR, certificate and profile are preserved
under ignored `.tools/signing/appgallery/`; none is committed to source control.
The certificate is valid through 2029-09-14 and matches the generated release key.

For 1.0.5, the signed upload file is
`dist/D-Mail-1.0.5-arm64-v8a-appgallery-signed.app`, with SHA-256 and
`*-signed-verification.json` sidecars identifying the exact source commit and
verified signatures. The matching unsigned artifact directory retains source and notices.
Signing uses the same release key, certificate and profile described below.

The previously completed 0.1.11 local upload file is:
`dist/D-Mail-0.1.11-arm64-v8a-appgallery-signed.app`.
This is a historical artifact; use the current 1.0.5 APP for a new upload.
A SHA-256 sidecar and `*-signed-verification.json` record are beside it.
Huawei's CLI 26 signing tool verified the APP and separate signed HAP signatures,
including the matching profile. All original ZIP member payloads remain unchanged;
the HAP additionally contains the tool's `.pages.info` signing metadata. The APP
uses the standard Hvigor signing flow: a signed APP container around the packaged
HAP. No AppGallery upload, review or physical-device installation was performed.

The signed artifacts derive from application/source revision
`d265c58d6fe0574a2a999a1ad67090f5f82230f8`. The existing unsigned build archive retains
the matching source and licenses. Its pending-signing notes describe the build
snapshot before the owner's signing materials arrived. Preserve the same release
key and CSR for future updates, and renew the certificate/profile as needed.

Huawei documents creating the release certificate using a CSR and signing with
its matching key and profile:
[Requesting a Release Certificate](https://developer.huawei.com/consumer/fr/doc/app/agc-help-release-cert-0000002283336729).

### Test-only upload and certificate checks

AppGallery Connect offers **Only testing** and **Testing and official release**
under Release app → Package management → Upload. Choosing Only testing does not
make the package eligible for official release; it must be uploaded again with
the other usage scenario. See Huawei's [package upload guide](https://developer.huawei.com/consumer/en/doc/app/agc-help-release-app-upload-pkg-0000002277983368)
and [package selection guide](https://developer.huawei.com/consumer/fr/doc/app/agc-help-release-app-choose-pkg-0000002278981434).

Huawei's [upload error guide](https://developer.huawei.com/consumer/fr/doc/app/agc-help-package-errorcode-0000002312513009#section1070911435820)
identifies unsigned HAPs as error 1014, and debug certificate/profile use for
formal release as error 999. It also checks profile/certificate agreement
(error 1001). These requirements concern the submitted package; any later
store distribution signing does not establish that an unsigned upload is valid.
The documentation checked on 2026-09-14 did not establish that Only testing
accepts debug signing. Do not label a debug-signed artifact as accepted by
AppGallery without checking the actual test-upload requirements/result.

The supplied profile has now been checked: type `release`, distribution
`app_gallery`, bundle ID `some.DMail.hamorny`, and the exact supplied certificate.
The existing development debug profile belongs to a different bundle ID and is
retained separately for existing device builds.

### Ordinary development identity

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
