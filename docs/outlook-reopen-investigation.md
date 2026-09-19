# Outlook reopen investigation after 1.0.5

Current delivery: these follow-up changes are consolidated into the 1.0.5 source
commit at the user's request. The latest signed development HAP is installed on
Pura X; see [incremental validation](incremental-mailbox-refresh.md) and the
adjacent JSON for its hash and evidence. The AppGallery APP predates these
changes. The dated stages below describe the investigation as it progressed;
installation and commit statements there are historical.

The user reports that the intermittent Outlook authentication failure usually
occurs after reopening the app. The earlier 1.0.5 cleanup audit found no removal
of OAuth configuration, callback handling, saved tokens or refresh behavior.
This investigation does **not** establish a complete authentication fix.

## Further D-Mail restart investigation

The user clarified that the dedicated test mailbox's reverting Outlook.com IMAP
setting is separate from the intermittent D-Mail failure on an already working
account. Do not use that test-account refusal as proof of the device symptom's
cause. No additional live provider attempts were made in this follow-up.

Two more synthetic regressions failed before the AccountStore correction:

- A failure retaining the encryption key, writing the refresh lease, encrypting
  rotated tokens or persisting them was converted to authenticationRequired.
  Unknown/malformed token-response failures were also treated as rejected login.
  The error classification now requires a known credential/grant rejection before
  offering reconnect. Local and unknown failures use the existing connection
  error instead. Explicit account-binding and standard OAuth rejection codes
  retain their authentication classification. Saved credentials remain intact;
  no token POST is automatically replayed. A synthetic later reopen recovers.
- A refresh that returned invalid_grant after a newer reconnect saved credentials
  still reported authenticationRequired. Only successful late refreshes had the
  existing supersession guard. Rejected refreshes now also compare the saved
  envelope before accusing the login. The obsolete operation stops as network;
  the new credentials stay saved and usable, without replaying the old request.

These are proven error-handling defects, not confirmation that either caused the
reported device failure. In particular the late-rejection race requires a newer
credential write during the older refresh, not merely an ordinary cold launch.

A separate synthetic crash scenario left a 60-second refresh lease behind and
reopened the store with eight simultaneous credential requests. All timed out
after the bounded 20-second wait with network, without issuing a token request.
An explicit request after lease expiry recovered with one refresh. This is a
potential explanation for a temporary failure after process termination during
refresh, but not for an exact authenticationRequired error. The lease and wait
policy are unchanged: blindly stealing a live owner's lease could race rotation.

Validation: full host run passed 853 JavaScript and 44 Python tests; the subsequent
crash-lease regression passed alongside all 24 credential tests, bringing current
JavaScript coverage to 854 tests. The signed ARM candidate compiled and package
verification passed using the existing native core. Prior Swift results remain
unchanged. The latest changes have not been device-tested, installed, committed
or published; version remains 1.0.5. No production mail or settings were accessed.

## Confirmed code changes

The bounded stress investigation reproduced an AccountStore teardown race.
`oauthAccessToken` could still be reading/decrypting the saved login before it
registered a refresh. `close()` waited for registered refreshes but not that
initial read, allowing the database to close underneath it. An expired login
then entered refresh with a closed database and surfaced an authentication error.
The store now owns the complete credential request until it settles, rejects new
requests after shutdown begins, and drains existing requests before closing.
Token rotation, endpoint/account binding, leases and saved account identities are
unchanged. There is no new automatic network retry.

The delayed-key regression failed before this change and passes afterward.
Twenty further host cycles exercise eight overlapping reads plus shutdown,
including five simulated key failures. They verify one refresh on successful
cycles, no lingering refresh lease, durable rotation after reopening, and
preservation of the existing credential after a key-read failure. This establishes
a code defect; it does not prove it caused every reported Outlook rejection.

`MailMessageLoader` rebuilt authentication errors with only their generic code,
dropping the existing allowlisted credentials/server/refresh stage. A regression
test failed before the correction and passes afterward. The normal error display
can now retain that distinction for reader failures. Provider descriptions and
secrets remain excluded. This repairs diagnosis, not server authentication.

The main-page notification-enable prompt is removed at the user's explicit
request, including its unused component and strings. Per-account notification
Settings, opt-in defaults and delivery preferences remain unchanged. The user
clarified that removing the prompt was the intent, not disabling selected accounts.

## Saved-token and live evidence

A synthetic test uses the production account store and encrypted credential
helper with independent committed SQLite readers. It closes/recreates the store,
restores the saved account and fresh access token, advances beyond expiry,
coalesces simultaneous refresh requests, saves token rotation and verifies a further
cold reopen uses the persisted result without another refresh. It passes.

The dedicated authorized Outlook test account had an expired token. One refresh
through the original Swift OAuth bridge succeeded with a recognized IMAP scope.
The rotated credentials were saved in desktop Secret Service before use. The
probe then exited; a fresh process restored only the persisted credentials and
made one original Swift IMAP authentication attempt. That failed specifically at
AUTHENTICATE with `authenticationRequired/server`. An independent Python IMAP
client using the same saved fresh token also received an authentication rejection.
No Inbox selection, mail read, send, account-setting change or automatic replay
was performed. Private tools/results remain under ignored `.tools/reopen-auth/`.

This establishes that the test failure occurs after successful refresh and
credential restoration. It does not prove the user's phone has the same cause,
that the token grant is sufficient for that mailbox, or that Microsoft alone is
at fault. It does not justify speculative retry loops or clearing saved accounts.
The distinction between a quick reopen and a reopen after an hour remains pending
user clarification. The exact phone error stage is still needed to link the two.

## Bounded live stress run

A separate 12-attempt authentication-only run used four warm-process original
Swift attempts, four fresh-process Swift attempts and four independent Python
attempts. Each connection was new, attempts were serial with a five-second gap,
and a 240-second watchdog bounded the run. Six attempts used the saved fresh
token; a planned refresh succeeded and was persisted to Secret Service before
the other six attempts. All 12 were rejected at AUTHENTICATE, including both
clients and both token cohorts. Durations were 785–3205 ms; the run took 75.5
seconds and all child processes stopped. No mailbox selection, mail read or send
was performed. Private results are in `.tools/outlook-stress/live-results.json`.

This independent rejection persists outside AccountStore, so the teardown fix
cannot explain or resolve the whole live-account symptom. No speculative token
endpoint change, account reset or production retry loop was added.

## Validation and delivery

All 851 JavaScript and 44 Python tests pass after the shutdown fix. The 49 Swift
OAuth tests passed in the preceding investigation; native protocol code is unchanged. The paired cleanup
audit is recorded separately under ignored `.tools/release-105/oauth-cleanup-audit/`.
The adjacent JSON record contains the local candidate build result. Version and
identities remain 1.0.5; the changes are uncommitted. The user subsequently authorized isolated synthetic MatePad tests. Their final
results are recorded below and in the JSON record. No production installation,
AppGallery rebuild/upload, GitHub push or production-app access was performed.

## MatePad native validation

The user authorized the connected MatePad (MRO-W00). The separately signed
`org.thunderbird.harmony.imaptest` app used synthetic Microsoft-shaped credentials,
the production AccountStore and OAuthSecretBox, and the real HarmonyOS encrypted
RDB and Asset Store. Refresh replies were synthetic; no provider connection or
mailbox access occurred. The emulator remained stopped and production was not
opened or updated.

Three native tests passed. The seed process saved the credential, was stopped,
and its absence was verified before a new test process restored that credential.
Eight store reopen cycles then completed 64 concurrent fresh-token reads without
refresh. Twelve more cycles closed the store immediately after starting eight
expired-token reads: all 96 reads succeeded, each cycle refreshed only once,
and 12 subsequent reads after reopen used the persisted rotation. Total: 172
credential reads, one verified process restart and 20 store reopen/refresh cycles.
The test bodies took about 10.7 seconds, excluding installation and runner startup.

The first setup attempt used an application context that RDB rejected; the fixture
now creates an entry-module context. The next setup attempt failed while saving
a protected credential. After the user continued, the unlocked Asset preflight
and all tests passed. Those setup failures are not attributed to Outlook.
The isolated app was stopped and uninstalled successfully. Artifact hashes and
counts are recorded in the adjacent JSON file; logs remain private under
`.tools/outlook-stress/matepad/`. The reproducible runner is
`scripts/test-matepad-oauth-reopen`, requiring both verified target variables.

The signed ARM development candidate includes the shutdown fix and retains
1.0.5 (1000005). It has not been installed into the production app identity.
The existing AppGallery release APP has not been rebuilt with these changes.

## Outlook mailbox-connection refusal classification

The next investigation compared continuation and initial-response XOAUTH2 against
two current DNS addresses of `outlook.office365.com`, retaining normal TLS
hostname verification. All four returned tagged NO after advertising XOAUTH2 and
SASL-IR. The saved token was fresh, its stored owner matched the configured test
account, and its response metadata included the recognized IMAP and SMTP scopes.
These checks do not independently establish the identity represented by an opaque
token. One SMTP authentication control returned 535; it attempted no delivery.

A further single, privacy-filtered wire check identified Microsoft's fixed
response **“User is authenticated but not connected.”** Only that predefined
category was saved, not raw response text or server/account details. The old
`authenticationRejected` helper classified uncoded NO and ALERT responses as
invalid credentials even for this message. A real TLS synthetic regression
reproduced that defect in password and OAuth paths before the change.

The Swift helper now recognizes this fixed, bounded response prefix only when
there is no structured code or the code is ALERT. It keeps the failure in the
connection/protocol category, so it cannot itself force browser reauthentication
or stop work as a bad credential. Explicit AUTHENTICATIONFAILED,
AUTHORIZATIONFAILED and EXPIRED codes retain precedence. Other uncoded rejections,
including similar but nonmatching prose, retain their previous behavior. No
response text is exposed, no credentials are discarded, and no immediate
request replay or new retry loop was introduced. Upstream source hashes and
protocol clients are unchanged; this is an explicit port-helper correction.

All 152 Swift tests in 39 suites pass, including TLS replay and classification
boundary tests. A newly linked original Swift live probe received a refusal but
reported `networkOrProtocol`, confirming the correction reaches the actual
exchange. This does **not** establish that the mailbox became reachable. The
previous `authenticationRequired/server` records describe the older client
classification; they were not proof of an invalid token or revoked consent.

The signed ARM development HAP was rebuilt with both the AccountStore shutdown
fix and this classification fix, still 1.0.5. It has not been installed or
published. The preceding MatePad storage stress results used the prior native
core and are not claimed as native execution of this later Swift change.

Microsoft's [OAuth documentation](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth)
confirms the configured scopes and XOAUTH2 format, and its
[Outlook.com settings documentation](https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com)
confirms the server/port and separately enabled IMAP access. The forwarding/IMAP
settings page is open for user-operated test-account sign-in, to verify the saved
setting and mailbox identity before attributing this refusal to an account or
service condition. No account settings have been changed.

## Protocol access does not remain enabled

After the user completed browser sign-in, the visible account matched the
configured dedicated mailbox. The forwarding/IMAP page initially reported the
IMAP switch enabled. The user then reported that it was disabled again after
sign-in. A fresh, separate settings-page load confirmed the IMAP switch **off**.
No toggle, Save control, account security option or permission was changed by
the agent. The user’s current mail page was left undisturbed; only settings
controls from the separate tab were inspected for this persistence check.

A bounded SMTP diagnostic also returned **535 5.7.139**, with the allowlisted
category **SMTP client authentication is disabled**. No raw server response,
account name, token or trace suffix is retained in the public record. That is a
protocol-access refusal, not proof of an incorrect password or OAuth grant.
The fresh disabled IMAP state plausibly explains the mailbox refusal, but this
observation cannot distinguish a failed settings save from a subsequent service
reset/policy override, or establish the cause for the user's other accounts.
The enabled state seen earlier must not be represented as durable verification.

Further live authentication retries are paused while the account's protocol
access does not remain enabled. Reauthorizing OAuth alone cannot enable IMAP.
The next useful account-side check is a user-operated enable/save followed by a
fresh settings load to establish persistence; if it reverts, the evidence is
ready for Microsoft account support. No tenant-admin or Basic-authentication
workaround is appropriate to infer for this personal Outlook.com account.
The local code corrections remain independently tested and uncommitted.

## Requested Pura X installation

At the user's subsequent request, the current signed 1.0.5 candidate was installed
in place on the verified Pura X (VDE-AL00), updating its development identity from
1.0.4 (1000004) to 1.0.5 (1000005). The signed input hash, installer success,
version, app/UID and database/Asset identities were verified unchanged apart from
the version. No uninstall or account reset occurred. The installer left a process
running; the agent did not launch it and explicitly stopped it, then verified
process absence. No mail or UI was inspected. This is installation validation,
not a successful real Outlook test. The separate AppGallery identity and MatePad
were not updated. Private install evidence is under .tools/outlook-reopen-install/.

## Cleanup while the user tests Pura X

OAuth requests now release tracking in try/finally. Shutdown waits once for the
complete credential requests, which include refresh and persistence; new requests
are already rejected while closing. Removed the duplicate refresh-only drain,
the unused readEmail diagnostic argument, six obsolete logger mocks and the
standalone synthetic Asset preflight. Failure tests now assert safe error codes
directly instead of checking an unused diagnostic collector. Cold-restart,
concurrent shutdown, account ownership and credential-rotation coverage remains.

All 854 JavaScript and 44 Python tests pass. The ARM app and isolated native test
HAP compile; signed app source/native-library parity verification passes. No
device commands or live provider requests were made during cleanup. The installed
Pura X artifact remains unchanged and is recorded separately from the rebuilt
local candidate. Swift protocol code was not changed in this cleanup.
