# Publishing D-Mail

The repository is [brunoyuv/DMail](https://github.com/brunoyuv/DMail); the app
display name is **D-Mail**. Local release packages are built with
`scripts/build-release`; see [release packages](release-packages.md).

## Name and compatibility

The repository title, app labels in both languages, package descriptions, sample
welcome text and browser return message use D-Mail. The generic mail icon is
original to this project. This is an independent project, not an official
Thunderbird or Mozilla product.

Upstream credits, URLs, license notices and source hashes still name Thunderbird.
The existing `org.thunderbird.harmony.dev` bundle ID, native ABI/library names,
database names, authenticated-data prefixes, build variables and local
`ThunderbirdPhone` emulator name are retained. Changing those in a branding pass
could break signing, in-place upgrades, saved credentials or native linkage.
The checkout directory may keep its existing local name; new clones can use
`D-Mail`. No account migration or device installation is part of this rename.

Before distributing binaries under a new package identity, arrange the matching
signing and OAuth configuration and plan an explicit data migration. Do not
change an installed account's OAuth client binding during a cosmetic rename.

## Source publication contents

The repository includes application sources, explicit upstream patches, source
hash manifests, third-party notices, synthetic fixtures and historical validation.
Device serials and a local Wi-Fi address have been redacted from the published
validation JSON; recorded artifact hashes and test outcomes are unchanged.
Historical screenshots contain synthetic mail and retain the UI of their date.

Ignored `.tools/` contains local toolchains, signing, OAuth configuration,
diagnostics and a private pre-publication backup. Ignored `upstream/` holds the
pinned source checkout. Neither belongs in a push. Do not force-add ignored files
or upload existing development HAPs as public releases.

Gmail browser sign-in is disabled by default through
`RegisteredMailOAuth.googleBrowserSignInEnabled`. Account setup directs users to
an app password, and Google browser reconnect is unavailable in the default UI.
Maintainers can explicitly change that build constant to `true` and rebuild to
experiment with browser sign-in. The switch does not delete saved OAuth accounts
or alter token refresh, encrypted storage, or the saved login binding.

The Google and Microsoft client IDs in `RegisteredMailOAuth.ets` are public
identifiers for the development registrations, not credentials or a promise that
other users can sign in. Fork maintainers must supply their own registrations
and update the matching client-ID check in
`scripts/generate-google-oauth-registration`. Google Desktop configuration goes
in ignored `.tools/oauth/google-desktop.json`. Never publish that file or its
generated native source. See [browser OAuth](browser-oauth.md).

Physical MatePad test runners require both `HDC_TARGET` and
`DMAIL_AUTHORIZED_MATEPAD_SERIAL`, set after verifying the authorized target.
They also check the model/architecture. Prefer the bounded emulator runners for
UI work. These variables do not authorize testing against real mail.

## Repository remote

The configured `origin` is `https://github.com/brunoyuv/DMail.git`, and `main`
tracks `origin/main`. Run `git remote -v` and inspect the pending commits before
an explicitly requested push. Local package creation does not push commits,
upload artifacts or create a GitHub release. The **Host tests** workflow validates
synthetic host tests; it does not build HAPs or run device tests.

Suggested repository description: “AI-assisted HarmonyOS mail port/rework with
ArkUI and the original Thunderbird Swift mail core.”

Source publication and a binary release are separate steps. Existing release
records describe development builds, not public downloadable releases. Public
binaries need their own validated signing, registration configuration and bundled
runtime notices in addition to matching source and provenance.
