# Outlook message failures and reconnect classification

The user reports that particular messages, especially Microsoft advertising
mail, repeatedly fail, lack inbox summaries, and can be followed by increasingly
widespread connection failures and a Reconnect prompt. Whether repeatedly
opening the same message is necessary is unknown. No real messages, account
credentials, device screens or production logs were inspected.

## Confirmed source behavior

- Inbox titles come from envelope metadata. When the server supplies no preview,
  `samplePreviews` fetches at most 2,048 encoded bytes per selected text part,
  grouped into at most four section requests with a one-second command timeout
  and a three-second loop budget. A failed optional request preserves headers.
- A valid HTML document whose initial sample contains only head/style content
  has no readable preview. This is reproduced with synthetic HTML and is not
  evidence of failed authentication or an unreadable complete body.
- Only nonempty cached previews populate `previewKnownIds`. Empty previews can
  therefore be sampled again during later page refreshes. The current tests do
  not establish that this traffic causes the reported account-wide failure.
- Missing bodies use fresh authenticated IMAP clients. Body reads are serialized
  by `MailMessageLoader`; an unresolved request holds that lane until it returns.
  Native requests have a 30-second outer deadline and cancellation, but a visible
  timeout alone is not proof that all native work has finished.
- The error-area Reconnect button requires `authenticationRequired`. Generic
  FETCH/parsing errors do not directly enable it. An IMAP authentication rejection
  (including an uncoded tagged NO), or failures classified by token-refresh
  handling, can enable it. The Accounts settings Reconnect action is separately
  available without an error.

## Narrow source correction

`OAuthTokenTransfer` previously reported HTTP 429, HTTP 5xx, `server_error` and
`temporarily_unavailable` as `rejected`. AccountStore converted that code to
`authenticationRequired`, producing a misleading reconnect prompt.

Those temporary token-endpoint responses now return the existing safe `network`
code. Saved credentials remain intact and no automatic token POST retry is
introduced. Actual credential rejection, including `invalid_grant`, retains its
existing behavior. Provider descriptions, tokens and account details remain
excluded from returned errors. This changes port adaptation code, not pinned
upstream sources, application identity, ABI, OAuth registration or permissions.

Microsoft documents the temporary OAuth errors in its
[authorization-code flow reference](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow#error-codes-for-token-endpoint-errors).
This correction is not evidence that token refresh caused the reported message
failures, and it does not establish a Microsoft IMAP quota or cooldown.

## Local validation

- A new URLSession transport regression failed on all seven temporary-response
  cases before the correction and passed afterward. All 47 host
  autoconfiguration tests pass.
- All eight OAuth reconnect JavaScript tests pass. The added test executes the
  shipping refresh/error-display methods with synthetic storage and verifies
  network versus authentication UI, unchanged credentials, one refresh request,
  lease release and key cleanup.
- All 11 inline-image/preview tests pass, including the new valid-HTML/blank-sample
  case.
- The preceding 34-test IMAP run includes nine synthetic message-read failures
  alternating with nine healthy reads: rejected FETCH, incomplete literal timeout
  and conflicting UID responses. Every connection closes and following healthy
  reads succeed. This does not reproduce device resource exhaustion or actual
  Outlook behavior.

Logs stay under ignored `.tools/outlook-*`. The message-specific failure and its
relationship to later connection failures remain unresolved.

## Corrected main-branch Pura X installation

The first user-requested install mistakenly used the OpenHarmony worktree,
whose app manifest still declared 1.0.3 (1000003). The device really was upgraded
from 1.0.2 to that build; this was a source-branch selection error, not just an
incorrect version description. That installation has now been superseded.

At the user's direction, the Outlook fix, its tests and these records were moved
to the existing `main` worktree at base revision
`c21edcea3143b97c8e7818bc983b00125b18cf4e` (1.0.4). Only this task's changes were
removed from the OpenHarmony worktree; its unrelated work remains intact.
The current 1.0.4 Connect-button changes remain included. The application version
stays **1.0.4 (1000004)**; the earlier binary was not relabeled.

On main, all **787 JavaScript, 40 Python and 47 Swift OAuth tests** pass. The ARM64
Swift core and signed HAP were rebuilt using the pinned CLI 26 / SDK 26 tools and
API 22 native sysroot. Verification checked production source parity, native
library hashes, the exact current Connect UI, version metadata, and the changed
OAuth source in native staging.

The verified Pura X (VDE-AL00) was upgraded in place from the mistaken 1.0.3 build
to **1.0.4 (1000004)**. Installer success and a separate fresh device query confirm
that version. App and storage identities are unchanged. Production was not
launched, and its process was absent after installation. MatePad was not changed;
no emulator was started.

Signed installer-input HAP SHA-256:
`5ad2379b55d718860508dddf53e424802b688e38c8d74971eee8c93f730aa3ea`.
This hash verifies the input sent to the installer, not a direct read of the
installed HAP (previous OS attempts denied that access). See
[installation validation](outlook-message-failures-validation.json), which also
retains the superseded install record. The actual Outlook message failure has not
been retested against a real account. No commit, push or public release was made
for this follow-up.


## Main checkout and sender-domain isolation

The primary workspace is now checked out on `main` at `c21edce` (1.0.4), with
this follow-up retained as uncommitted changes. The dirty OpenHarmony branch was
moved to `.tools/openharmony-preserved`; its tracked diff and every untracked file
were compared byte-for-byte with the pre-switch backup. The previous nested main
worktree is detached and clean. No history was rewritten or pushed.

`AccountSessionTests.repeatedMessageFailuresCloseEachConnectionAndDoNotPoisonLaterReads`
now runs a 12-case matrix: password LOGIN and XOAUTH2 authentication, each with
`microsoft.com`, `email.microsoft.com`, `accountprotection.microsoft.com`,
`outlook.com`, `microsoft.com.example.test` and `control.example.test` as the
synthetic envelope sender's domain. Credentials and content stay identical while
sender identity changes. These are fixture values, not claims about Microsoft's
actual advertising sender domains.

Each case tests three failures (rejected FETCH, truncated literal timeout and
conflicting UID), repeated three times. Each failed body read is followed by a
fresh connection and successful healthy body read. Before **every** body attempt,
the original Swift client authenticates, selects INBOX, fetches two headers,
checks the decoded sender/subject and requests bounded preview samples. The
failing message has an empty sample; the healthy message has a usable sample.
All 216 header reads, 108 expected body failures and 108 healthy body reads pass;
all connections close, with exactly one authentication per connection and no
message failure classified as authentication rejection. Half of these operations
use XOAUTH2, the IMAP authentication mechanism behind Microsoft browser sign-in.

The focused IMAP run passes **42 tests in eight suites**, including those 12
matrix cases. Source inspection found no Microsoft sender-domain condition in
the inbox, preview or body paths; the Microsoft SMTP endpoint configuration is
unrelated to the message's From address. The long-HTML blank-preview regression
and reconnect error-classification tests were also rerun.

This is host-side synthetic evidence for the original protocol client and
separate preview/reconnect units. It is not an end-to-end HarmonyOS inbox test,
a browser consent test, or a reproduction against Microsoft's service. It does
not rule out a particular real message structure, server throttling or device
resource pressure. Sender domain alone did not reproduce the failure in this
matrix. No additional production code change was justified by these results;
the transient-token-error fix above remains applied. No device was changed in
this testing round and the emulator remained stopped. Logs are in ignored
`.tools/outlook-sender-main/`.
