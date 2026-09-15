# Browser OAuth port

## D-Mail default

D-Mail disables Google browser sign-in and Google browser reconnect by default.
For Gmail, use an app password in the IMAP password field. Google requires
2-Step Verification to create app passwords, and some account types do not offer
them; see [Google’s app-password instructions](https://support.google.com/accounts/answer/185833).
Microsoft browser sign-in and existing saved OAuth token validation/refresh remain
unchanged. An explicit build opt-in is documented in [publishing](publishing.md).
The sections below record the earlier experimental OAuth implementation and tests.

The port reuses Thunderbird's original OAuth request/PKCE helpers and original
Swift IMAP and SMTP clients. Account setup offers Google and Outlook.com browser
sign-in alongside password/app-password setup. Gmail keeps both choices. Real
account testing belongs to the user; automated tests use synthetic mail only.

## Registration and browser callback

The user created a Google Desktop client and a Microsoft personal-account client
named `TMl for HOS`. Local registration IDs are recorded in ignored
`.tools/oauth-registration-status.json`; the Google Desktop secret is supplied through ignored local native build configuration.
The Google TV client is unsuitable for Gmail scopes and is not used. Google's
Desktop loopback approach remains experimental on HarmonyOS; live acceptance and
external-browser background behavior have not been verified.

The Microsoft registration's native redirect was saved by the user and observed
in Azure: `http://127.0.0.1:49152/oauth2redirect`. The HarmonyOS listener binds that
exact port before launching the browser. If occupied, sign-in fails without
opening the browser or switching to an unregistered address. Google continues to
use an OS-assigned loopback port. Both listeners bind IPv4 loopback only, expire
within ten minutes and close on terminal callback/cancellation.

Swift validates the exact redirect, random state and PKCE before exchanging a
single-use code. Token POSTs have bounded input/output, deadlines, sanitized errors
and no redirect following. The browser response never echoes a code or token.

The Microsoft app requests the full Outlook IMAP and SMTP delegated scopes plus
`offline_access` during sign-in. These can use dynamic consent without manually
adding the Exchange API to the new directory. The app's current Microsoft provider
uses the `consumers` authority for the user's personal-account registration.
Google's project remains in testing. The user added their test account personally;
the console showed one test user during the failure investigation. App-password
setup remains available. No provider sign-in or mailbox consent was performed by automation.

References: [Microsoft mail OAuth](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth),
[dynamic consent](https://learn.microsoft.com/en-us/entra/identity-platform/consent-types-developer),
[redirect rules](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url),
[Google native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app).

## Native mail authentication

`port/swift-imap/oauth.patch` adds a handler factory to Thunderbird's command
pipeline and exposes `IMAPClient.authenticateXOAUTH2`. The port's handler uses
the original NIOIMAP codec, supports SASL-IR and the initial continuation, refreshes
post-authentication capabilities, and sends a token only once. The email identity
and server login remain independent. Missing XOAUTH2 support and rejected tokens
fail without password fallback.

`port/swift-smtp/oauth.patch` extends the original SMTP state machine and encoder.
Bearer authentication works after verified implicit TLS or STARTTLS. An OAuth
error challenge receives an empty response, and even a later success reply cannot
authorize a message after that rejection. No automatic message retry was added.

## Evidence on 2026-09-14

- 41 host mail tests passed in a clean scratch build, including seven IMAP and
  four SMTP OAuth tests. The initial reused scratch build had unrelated body
  encoding failures; the clean build passed without body source changes.
- `scripts/test-emulator-mail-oauth`: seven native tests passed against synthetic
  local TLS servers: ten IMAP sessions, three SMTP sessions, both IMAP SASL styles,
  SMTP implicit TLS and STARTTLS, rejected tokens, unsupported mechanisms, no
  password fallback, exact synthetic message body and connection cleanup.
- `scripts/test-emulator-oauth`: twelve native bridge/socket tests passed,
  including Microsoft fixed-port return and occupied-port refusal. The browser
  launcher is injected; this does not prove a live provider login.
- Each bounded run stopped the emulator. A separate native-process check found
  no emulator process afterward.

Additional evidence: 41 host discovery/OAuth tests passed. Nine native storage
and account tests passed, covering schema-4 password-account migration, large
token sets, authenticated encryption, refresh rotation/coalescing, removal races
and SMTP endpoint binding. Five discovery/UI checks passed at each of Pura X
main, Pura X cover and MatePad landscape sizes. The cover alone hides the system
status bar.

Hashes and logs are recorded in `port/swift-autoconfiguration/oauth-validation.json`
and `port/swift-imap/oauth-validation.json`. Native runs used the same x86_64
Swift core bytes as the staged production app. Device installation evidence is
recorded separately; installation does not prove live provider authentication.

## Persistence and refresh

Schema 5 preserves existing password accounts. OAuth tokens are encrypted with
AES-256-GCM using a fresh nonce and account-bound authenticated data. The encrypted
RDB stores the ciphertext; HarmonyOS Asset Store holds only a per-account 32-byte
key, avoiding its 1024-byte secret limit. Keys require device unlock and do not sync.
Token rotation is saved before use, concurrent refresh requests are coalesced,
and removal during refresh cannot recreate an account. SMTP validates its saved
host and login before receiving a token. No automatic delivery retry was added.
See [Huawei Asset constraints](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/asset-native-update).

## User testing

Live Google/Microsoft sign-in, external-browser background behavior and actual
mailbox access remain unverified and are left to the user. Google Desktop loopback
support on HarmonyOS is experimental. The update is installed without launching
the production app; saved accounts are preserved. This round stops after its
synthetic tests and installation on both requested devices.

## Device update on 2026-09-14

The signed ARM build passed source/library parity verification and installed with
`hdc install -r` on Pura X (VDE-AL00) and MatePad (MRO-W00). Both installers reported
success. The production app was stopped before installation and was not launched
afterward. No real mailbox was accessed. Installation evidence and the artifact
hash are in `.tools/oauth-device-install.json`. The emulator is stopped.

## Google sign-in failure follow-up

The user reported browser sign-in completing before the app showed a generic
failure. An authorized screenshot confirmed that message, but not the cause.
The follow-up separates callback preparation, request preparation, browser launch,
callback waiting, token exchange, IMAP connection and account persistence errors.
Only allowlisted protocol error codes are displayed; raw provider descriptions
and error messages never reach the UI. Standard token endpoint rejections such as
`invalid_client` and `invalid_grant` now cross the native bridge safely. This is
diagnostic support, not evidence that the live Google failure is fixed. The user
will retry sign-in personally; no automated real-account attempt is performed.

Follow-up validation: 42 host tests and 13 native OAuth checks passed. The signed
ARM update passed source/library parity verification and installed successfully
on Pura X via Wi-Fi, preserving accounts. The app was not launched. The emulator
stopped and its native process exit was verified. See
`port/swift-autoconfiguration/oauth-diagnostics-validation.json`.

## Missing Google Desktop client authentication

The subsequent user screenshot reported `invalid_request` at token exchange.
A Google token POST using the actual public client ID and a deliberately fake
code returned `client_secret is missing.` The user's saved 00:58 screenshot
contained the matching Desktop registration. After correcting an ambiguous
uppercase I during transcription, a fake-code request with that registration
returned `invalid_grant`, passing client validation without account access.

The original Swift request/PKCE code remains in use. A narrow native adapter adds
the issued Desktop secret only to the matching client's Google token POST, for
both code exchange and refresh. It never enters browser URLs, Microsoft requests
or account/token database records. `.tools/oauth/google-desktop.json` and the
generated native source are private-mode files outside source control. The secret
is necessarily recoverable from the installed prototype binary; it is an app
registration value, not a user's password or mailbox token. No client secrets
belong in repository sources, logs or validation records. Host tests always use
a nil local registration and synthetic secrets for the adapter tests.

Validation: 46 host tests and 13 native OAuth checks passed. Both native builds
and the signed ARM HAP contain the configured registration, while repository
files do not. Pura X installation succeeded with accounts preserved and no app
launch. The emulator exited. Live sign-in is left to the user. Evidence:
`port/swift-autoconfiguration/google-desktop-validation.json`.
