# D-Mail

An experimental, AI-assisted port and rework for HarmonyOS, developed with
OpenAI Codex. It combines a native ArkUI interface with the original Swift mail
core from
[Thunderbird for iOS](https://github.com/thunderbird/thunderbird-ios).

D-Mail is an independent project, not an official Thunderbird or Mozilla
product. Thunderbird references in source provenance and license notices credit
the upstream work. The app uses its own generic mail icon.

## Status

The current release is **1.0.5**. The full port is unfinished. Synthetic host
and native tests cover the implemented workflows; live-provider compatibility
is not comprehensively verified.

- IMAP mailboxes, paging, read/unread flags, stars, archive and server Sent folders.
- SMTP composition, Reply / Reply All / Forward, sender names, signatures and
  encrypted drafts, with explicit recovery for uncertain delivery.
- HTML reading, conversation grouping, attachment download/open/save, and remote
  pictures loaded in a bounded batch after opening a message and cached for reuse.
- Multiple accounts, encrypted account records and drafts, and app-private body
  and picture files with seven-day downloaded-mail retention. Cached messages
  open before network refresh.
- Foreground Inbox body prefetch, bounded reuse of IMAP connections, and paired
  MIME fetches for faster opening.
- Foreground Inbox updates, per-account optional alerts, persisted unread badges
  and OS-deferred background checks, connecting directly to the existing mail server.
- Optional Markdown and TeX math reading, two equation renderers, composer
  preview, and normal Copy that retains equation source.
- English and Simplified Chinese, light/dark appearance, phone and tablet layouts.
- Provider discovery, password/app-password setup and experimental Microsoft
  browser OAuth. Gmail browser sign-in is disabled by default; use an app password.

The public background scheduler currently has a two-hour minimum; minute-level
background checking remains unresolved. No privately operated relay is required.
JMAP has a native reader and message-action path; submission and full parity
remain unfinished. See [background checking](docs/background-checking.md),
[OAuth configuration](docs/browser-oauth.md) and the latest
[release validation](docs/release-1.0.5.md).

## Markdown and equations

Enable **Markdown and math** in the account settings to render while reading.
Choose **D: native MathML** with Fira Math, or **C: CommonHTML**. Use `$...$` for
inline equations and `$$...$$` for display equations; `\(...\)` and `\[...\]`
are supported too. The composer’s **More → Preview** shows the formatted result.
Sending preserves the original Markdown/TeX text.

Version 1.0.3 removes the equation-count cap and preserves the original equation
source when copying an equation or a paragraph. Input, individual-expression and
output-size safeguards remain. Native MathML selection can add line breaks around
inline equations; device clipboard behavior still needs user verification.
Literal equations in HTML replies are supported when the delimiters and expression
remain together in a text run. Code/preformatted content stays literal, and
existing equation images cannot be converted back into TeX. See
[Markdown and math](docs/markdown-math.md) for details and limitations.

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
notices. Use `./scripts/build-release --appgallery` for the separate registered
store identity. The upload artifact is the release-signed `.app`; the ZIP carries
matching source and notices for GitHub distribution. Device installation requires
appropriate signing. See
[release-package instructions](docs/release-packages.md).

## Development

Host tests require Node.js 22, npm and Python 3 (including SQLite support).
Install the pinned renderer/font dependencies and regenerate local font assets:

```sh
npm install --prefix .tools/test --ignore-scripts --no-audit --no-fund typescript@5.9.3
python3 -m venv .tools/test-python
. .tools/test-python/bin/activate
python3 -m pip install fonttools==4.60.1 brotlicffi==1.0.9.2
mkdir -p .tools/math-render
cp port/markdown-math/package.json port/markdown-math/package-lock.json .tools/math-render/
npm ci --prefix .tools/math-render --ignore-scripts --no-audit --no-fund
python3 port/markdown-math/build-mathml-font.py
node port/markdown-math/build.cjs
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
| `harmony/` | ArkUI app, local storage and native bridge |
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
**Marked remains MIT-licensed**, MathJax and its TeX fonts remain Apache-2.0,
and Fira Math remains OFL-1.1. These component licenses are not replaced by MPL.
See the [renderer provenance and licenses](port/markdown-math/README.md).
The repository name and visible app name are D-Mail. Legacy internal package,
database and native-library names remain for installation and data compatibility;
see [the rename notes](docs/publishing.md#name-and-compatibility).
The [Mozilla FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) explains the license’s
file-level scope.
