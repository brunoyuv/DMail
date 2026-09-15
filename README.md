# D-Mail

An experimental, AI-assisted port and rework for HarmonyOS, developed with
OpenAI Codex. It combines a native ArkUI interface with the original Swift mail
core from
[Thunderbird for iOS](https://github.com/thunderbird/thunderbird-ios).

D-Mail is an independent project, not an official Thunderbird or Mozilla
product. Thunderbird references in source provenance and license notices credit
the upstream work. The app uses its own generic mail icon.

## Status

The current development baseline is **0.1.11**. The full port is unfinished.
Synthetic host and native tests cover the implemented workflows; live-provider
compatibility is not comprehensively verified. The D-Mail rename and Gmail
app-password default follow this baseline; older release records and screenshots
retain their historical names and behavior.

- IMAP mailboxes, paging, read/unread flags, stars, archive and server Sent folders.
- SMTP composition, Reply / Reply All / Forward, sender names, signatures and
  encrypted drafts, with explicit recovery for uncertain delivery.
- HTML reading, conversation grouping, attachment download/open/save, and remote
  pictures loaded with per-message consent and cached for reuse.
- Multiple accounts, encrypted local storage and seven-day downloaded-mail
  retention, with cached reading before network refresh.
- Foreground Inbox updates, per-account optional alerts, persisted unread badges
  and OS-deferred background checks, connecting directly to the existing mail server.
- English and Simplified Chinese, light/dark appearance, phone and tablet layouts.
- Provider discovery, password/app-password setup and experimental Microsoft
  browser OAuth. Gmail browser sign-in is disabled by default; use an app password.

The public background scheduler currently has a two-hour minimum; minute-level
background checking remains unresolved. No privately operated relay is required.
JMAP has a native reader and message-action path; submission and full parity
remain unfinished. See [background checking](docs/background-checking.md),
[OAuth configuration](docs/browser-oauth.md) and the latest
[release validation](docs/release-0.1.11.md).

## Gmail and your own OAuth registration

Gmail browser sign-in is disabled in default builds. Use a Google app password
for the default setup; see [Google's app-password instructions](https://support.google.com/accounts/answer/185833).

The MPL-2.0 source is available to modify and rebuild. Anyone using Gmail who
builds their own copy of D-Mail can add their own Google OAuth registration:

1. Create your own Google **Desktop app** OAuth client and configure its consent
   screen and permitted users in your Google project.
2. Set `RegisteredMailOAuth.googleBrowserSignInEnabled` to `true` in
   `harmony/entry/src/main/ets/mail/oauth/RegisteredMailOAuth.ets`, and replace
   that file's Google client ID with your own.
3. Set the matching `expected` client ID in
   `scripts/generate-google-oauth-registration`. Save the issued Desktop client
   JSON locally as `.tools/oauth/google-desktop.json` (keep the `installed`
   object from Google's download). This ignored file contains the client secret;
   keep it out of commits and shared logs.
4. Rebuild the native core and HAP using `./scripts/build`, or
   `./scripts/build-device-app` for a configured ARM/signing environment.

This is a build-time customization. Google's registration and consent
requirements still apply, and browser sign-in remains experimental on HarmonyOS.
Changing the client ID also changes the binding for saved OAuth accounts; use
your own registration from the start of a fresh setup. Details and historical
validation are in [the OAuth notes](docs/browser-oauth.md).

## Release package

The repository is [brunoyuv/DMail](https://github.com/brunoyuv/DMail).
With the native toolchain prepared and source changes committed, run
`./scripts/build-release` to create a local ARM64 release-mode package under
`dist/`. It includes an unsigned HAP, checksums, matching source and license
notices. Device installation requires signing. See
[release-package instructions](docs/release-packages.md).

## Development

Host tests require Node.js 22, npm and Python 3 (including SQLite support):

```sh
npm install --prefix .tools/test --ignore-scripts --no-audit --no-fund typescript@5.9.3
./scripts/test
```

The GitHub Actions workflow runs these synthetic tests without a device, signing
keys or an email account. Native HAP builds additionally need Huawei's toolchain,
the pinned upstream checkout, and the custom Swift runtime. They are not a
one-command build from a fresh clone. Follow
[environment setup](docs/environment.md),
[the Swift runtime build](port/swift-runtime/README.md), and
[native core integration](docs/native-core.md).

```sh
mkdir -p upstream
git clone https://github.com/thunderbird/thunderbird-ios.git upstream/thunderbird-ios
git -C upstream/thunderbird-ios checkout --detach 61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf
# After completing the toolchain and native-runtime setup:
./scripts/build
```

The HAP build uses CLI 26.0.0.821, Hvigor 6.26.4 and SDK 26.0.0.105.
Minimum/target compatibility and the Swift native sysroot remain API 22.
Tools, upstream downloads, signing, credentials and build output stay outside Git.

Keep the emulator stopped during coding and builds. Run prepared native tests
through `scripts/with-test-emulator`, which bounds execution and stops the emulator
on exit. Use synthetic fixtures; real mailbox access and provider sign-in are
user-operated. Preserve saved accounts with in-place upgrades.

## Project map

| Path | Contents |
| --- | --- |
| `harmony/` | ArkUI app, encrypted storage and native bridge |
| `port/` | Swift adapters, explicit upstream patches, provenance and fixtures |
| `scripts/` | Toolchain setup, builds and bounded validation runners |
| `tests/` | Synthetic host regression tests |
| `docs/` | Architecture, workflow notes and historical release evidence |
| `licenses/` | Third-party license texts |

See [contribution guidance](CONTRIBUTING.md),
[upstream reuse](docs/upstream-reuse.md), and
[GitHub publication notes](docs/publishing.md).

## License and attribution

D-Mail uses the [Mozilla Public License 2.0](LICENSE), the same file-level
copyleft license as Thunderbird's upstream source. Component-specific notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `licenses/`.
Upstream source headers, patch provenance and dependency licenses are retained.
The repository name and visible app name are D-Mail. Legacy internal package,
database and native-library names remain for installation and data compatibility;
see [the rename notes](docs/publishing.md#name-and-compatibility).
The [Mozilla FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) explains the license’s
file-level scope.
