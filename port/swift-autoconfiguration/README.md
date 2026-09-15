# Thunderbird autoconfiguration port

This work stages 13 original `Core/Sources/Autoconfiguration` files from the pinned
iOS revision, with six original test files. The manifest records hashes and the
five source files excluded from this stage. `harmonyos.patch` makes every upstream
adaptation reviewable. The original checkout is untouched.

The staged module retains provider server order, separate login placeholders,
SSL/STARTTLS choices, OAuth metadata and provider/well-known/ISPDB URL generation.
The parser now accumulates XML text/CDATA before replacing placeholders, rejects
malformed/oversized documents and entity declarations, and scopes fields to their
proper parents. Unknown authentication/protocol/security values are retained as
unsupported choices rather than rejecting the entire provider document. They do
not imply that a transport or authentication mechanism is implemented.

FoundationXML and FoundationNetworking replace Apple's combined Foundation
imports. The original PKCE helper uses a small OpenSSL SHA-256 adapter. Token
requests retain the original POST behavior, add the form content type and encode
literal plus signs correctly. OAuth host matching requires a domain boundary.
Discovery domain input cannot introduce URL paths, ports, queries or fragments.

Run `scripts/test-autoconfiguration` for the original host tests plus compatibility
regressions. `scripts/build-native-autoconfiguration` compiles/links a standalone
HarmonyOS module; set `THUNDERBIRD_SWIFT_ARCH=aarch64` for ARM. Neither command
changes the shipping HAP or starts the emulator.

`scripts/prepare-native-app` now includes this module and FoundationXML in the
shipping core. The account form uses a Node-API worker for bounded HTTPS acquisition
(512 KiB, eight seconds per source, at most three HTTPS redirects) and retains the
original provider/well-known/ISPDB priority. Malformed or unavailable sources fall
through; valid unsupported configurations retain their priority. Proposals show
incoming/outgoing choices and can fill the editable manual fields. The separate
outgoing username is stored alongside new account credentials.

The 28 host tests cover the original models, parser boundaries, source fallback,
unsupported authentication, username substitution and shared C-response ownership.
Native execution and UI tests are in `Discovery.test.ets`; run the prepared HAPs
with `scripts/test-emulator-discovery`. Native/public HTTPS and UI results should
be read from that run, not inferred from host test success.

Remaining work includes platform DNS/MX/SRV support, editing existing incoming
accounts and IMAP STARTTLS/authentication expansion. The original
public-suffix parser still needs wildcard/exception validation before MX fallback.

Browser OAuth is not yet enabled in account setup. `BrowserOAuth.swift` wraps the
original OAuth request/PKCE helpers with validated endpoints, state and exact
redirect binding, ten-minute sessions, cancellation and single-use callbacks.
`OAuthTokenTransfer.swift` bounds token POSTs and rejects redirects. Provider
endpoints/scopes are fixed in `MailOAuthProvider.swift`; client IDs and redirects
must come from actual registrations. `OAuthBridge.swift` and
`NativeBrowserOAuth.ets` expose these operations on a Node-API worker.

There are now 40 host tests: the earlier 28 discovery/model tests, nine browser
session/token tests and three URLSession transport tests. The prepared
`scripts/test-emulator-oauth` runner passed twelve tests: four native bridge tests,
four real HarmonyOS TCP callback tests and four browser-flow lifecycle tests.
These cover generated authorization requests, fragmented HTTP, malformed requests,
state rejection, denial, cancellation, timeout, port cleanup and launch failure.
They use synthetic client IDs, never contact OAuth providers, and do not prove
live sign-in. The emulator is automatically stopped after the bounded run.

`LoopbackOAuthListener.ets` binds only `127.0.0.1` for up to
ten minutes, caps connections and HTTP input, and validates the Host and callback
path. Google uses an OS-assigned port; Microsoft binds the registered port 49152
before launching a browser and refuses an occupied port. Swift checks state and
the exact redirect before exchanging a code. No URL,
code or token is echoed to the browser. The port closes after a terminal response,
cancel or timeout. `LoopbackBrowserSignIn.forContext` uses HarmonyOS `openLink`;
the native tests inject a browser launcher and exercise real socket callbacks.
The actual external browser and app background behavior are not yet verified.

The user created a Google Desktop app registration for an experimental loopback
flow. Google does not document HarmonyOS as a supported native platform. The TV
client the user also created cannot request Gmail scopes and is not used. The
user subsequently created an Azure directory and a personal-account Microsoft
client, and saved its native loopback redirect. See [browser OAuth](../../docs/browser-oauth.md).

Account setup, registered client selection, the Microsoft consumers authority,
encrypted token persistence and coordinated refresh are connected. Gmail offers
both browser sign-in and app-password setup. Live browser/provider verification
is left to the user, who declined automatic mailbox access and Google test-user
addition. No existing Thunderbird registration is reused,
and the Google Desktop secret is kept out of repository sources.

IMAP/SMTP XOAUTH2 now passes seven synthetic native TLS tests using the original
Swift clients. This is transport evidence, not a completed live OAuth account flow.

Format reference: [Thunderbird autoconfiguration specification](https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat).
