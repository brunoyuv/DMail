# Newsletter fetch and cache test — 2026-09-15

The user reported that one Microsoft Store newsletter consistently remains empty
or fails to download, supplied its original EML, and requested controlled tests
on both the emulator and MatePad.

## Result

All seven scenarios passed on both platforms using the 1.0.1 production Swift
core for each architecture and current production ArkTS loader/storage code.
This did **not** reproduce the persistent failure of the user's message.

| Scenario | MatePad | Emulator |
| --- | --- | --- |
| Complete single-part HTML/base64 FETCH | Pass | Pass |
| Split FETCH records, fragmented literals and unsolicited FLAGS | Pass | Pass |
| Missing MIME section headers, then explicit retry | Pass | Pass |
| Zero-byte body despite nonzero advertised size, then explicit retry | Pass | Pass |
| Connection dropped partway through body literal, then explicit retry | Pass | Pass |
| Body FETCH stalls, then explicit retry | Pass | Pass |
| Saved failed-empty body entry, then explicit load | Pass | Pass |

For each injected fetch failure, the body remained incomplete, another uncached
message loaded after the failed operation drained, and an explicit retry of the
original synthetic message succeeded. Successful bodies and prepared documents
survived closing/reopening the account store without new IMAP connections or
changes to the body download timestamp.

The stalled-request scenario, including subsequent successful loads and cache
reopening, took 11.30 seconds on MatePad and 10.80 seconds on the emulator. This
is the real native command timeout path; it does not test an indefinitely
unresolved credentials, NAPI queue, or storage operation.

All injected malformed/incomplete responses surfaced as `network` through the
current loader. The first MatePad run stopped because the test expected
`invalidResponse` for missing headers. The expectation was corrected to accept
either existing failure category while still requiring rejection, no completed
cache entry, successful subsequent fetch/retry, and no unintended requests.
No production code was changed to make the test pass.

## Method and boundaries

- Used an anonymized derivative of the supplied EML: single-part UTF-8 HTML,
  base64 transfer encoding, 56,342 encoded body bytes and 41,172 decoded bytes.
  Preserved markup, CSS, Unicode/entity patterns and dimensions; replaced
  addresses, visible alphanumeric content and remote destinations. The original
  EML's standalone decoding had already passed separately.
- Ran a loopback TLS IMAP fixture through HDC reverse forwarding with synthetic
  credentials. Exercised the original Swift IMAP client, BODYSTRUCTURE selection,
  MIME section fetching, assembly/decoding, the NAPI bridge, MailMessageLoader,
  AccountStore and persistent body/prepared-document storage.
- Each platform recorded exactly 17 IMAP connections and 16 body-section
  requests, zero unexpected commands, and zero active connections at completion.
  Each connection fetched body sections at most once. Cache reopen made no
  connection. No remote pictures were downloaded.
- Verified packaged Swift core bytes against the corresponding production core.
  The x86 emulator and ARM MatePad used separately built isolated HAPs.
- Installed only `org.thunderbird.harmony.imaptest`; stopped and uninstalled it
  afterward. Removed fixture processes/forwarding and independently verified the
  emulator's native process had exited. Production was not opened or accessed.

The fixture supplies controlled, valid BODYSTRUCTURE metadata. It cannot show
what the private server actually returned for the affected UID, nor reproduce an
uninspected production cache record or every possible exception. Passing these
tests does not establish that the reported message is healthy in D-Mail.

## Local evidence

Private source-derived fixtures, runners, build/test logs, per-device server
statistics and package/harness hashes are under ignored
`.tools/newsletter-fetch-check/`. `validation.json` records the source commit,
core/package hashes, seven passing cases per platform and cleanup checks.
The initial expectation failure remains in `matepad-first-attempt/`.

No release package, local release history or production installation was changed
by this diagnostic round.

## Follow-up: folder size and sixth/ninth positions

The user identified another failing message, described the positions as sixth
and ninth from the end, could not count the folder, and authorized varying
synthetic folder sizes. The native comparison passed on both MatePad and emulator
for **9, 49, 50, 51, 55, 56, 58, 59, 64, 65, 199, 200, 201, 1,000 and 5,000**
messages.

Each platform traversed all **150 header pages / 7,116 headers** and loaded
**177 bodies**. The anonymized newsletter appeared sixth/ninth from both ends;
neighboring messages served as controls. Counts 55/56 and 58/59 move the newest-end
targets across a 50-message page boundary. Synthetic UIDs differed from sequence
numbers. Header order, unique identities, per-message body markers, complete
newsletter content, prepared-document availability and cache timestamps were
checked. All selected bodies reopened after closing/reopening the account store
without additional connections. Cached records accumulated within each group.

The initial combined MatePad test printed all 15 scenario passes but exceeded
its 180-second Hypium deadline during final cleanup. The final test split the
matrix into two groups with a 120-second deadline each; both groups then passed
on each platform. The largest scenario, including 100 header pages, storage,
selected body downloads and cache reopen, took 69.51 seconds on MatePad and
44.82 seconds on the emulator. Those are whole-scenario timings, not individual
body-download latency.

Both isolated apps were stopped and uninstalled. Fixture processes and forwards
were removed, all IMAP connections were closed, and native emulator-process
absence was independently verified. Evidence, hashes, the initial deadline
failure and the final validation record are in ignored
`.tools/newsletter-count-check/`.

This exercises native protocol, loader and cache behavior, not automated reader
UI gestures. It does not reproduce actual Microsoft server responses or OAuth:
the local fixture authenticates with synthetic password credentials. No count
or position failure was reproduced within these cases.

## Follow-up: Microsoft OAuth warning

The user clarified that this affected account is Outlook/Hotmail with Microsoft
sign-in, that D-Mail shows its reconnect warning, and that new mail still arrives.
This supersedes the earlier private-server assumption for this particular issue.

The current app has no OAuth email-count quota. It uses the saved token's issued
expiry and refreshes before use when no more than 60 seconds remain. Native
token requests have a 15-second bound; another operation awaiting the refresh
lease owner waits at most 20 seconds. These are token/operation timing limits,
not a requirement to sign in every hour.

All 18 existing host credential/refresh tests passed. Two additional diagnostic
probes confirmed that `AccountStore.refreshOAuth` currently reports
`authenticationRequired` for both:

- A malformed token response (`invalidTokenResponse`), without credential
  rejection.
- A successful synthetic token refresh followed by failure to persist the new
  credentials locally.

Both probes preserve the previous encrypted credential record and use no real
account or provider. All 20 combined checks passed; the extra probes deliberately
assert the current misleading classification, not corrected behavior.
`ConnectedMail.showError` maps that classification to the generic unlock/token/
reconnect warning. This confirms overbroad error reporting but does not identify
the cause of the user's incident. No authentication implementation or warning
text was changed in this investigation.

Arrival hints may reuse an existing IMAP IDLE connection while selected body
downloads open a fresh IMAP connection. Therefore continued arrivals do not by
themselves prove that fresh connections can authenticate, or establish that the
warning was false in this instance.
