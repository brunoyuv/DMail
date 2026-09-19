# D-Mail 1.0.5

Version **1.0.5**, code **1000005**, consolidates the fixes tested during the
1.0.4 follow-up. The user confirmed that the installed fetch optimization makes
loading faster and requested this release and removal of the debug feature.

## Changes

- Foreground Inbox pages and bodies reuse a bounded, credential-bound original
  Swift IMAP read session. Active Inbox body prefetch pauses for lifecycle,
  interaction and thermal limits; pictures and attachment files stay on demand.
- Adjacent MIME parts share one bounded FETCH command, reducing round trips.
  Singlepart HTML uses the root HEADER. UID, size, cancellation and partial-body
  checks remain intact, with no automatic replay after a rejected batch.
- The IMAP client waits for the server greeting before issuing commands.
  OAuth refresh preserves newer reconnect credentials and keeps safe error stages.
- Opening messages clears manual unread state, including combined replies.
  Missing Gmail password-account SMTP settings offer explicit saved-login recovery.
- The in-app download debug feature is removed: no Settings section, log export,
  logger initialization or ArkTS trace requests. Old enabled preferences cannot
  reactivate it. Optional native trace hooks remain only for synthetic probes.
- AppGallery packaging checks the four-segment virtualMachine value against the
  compiled bytecode header, preventing the previously reported malformed metadata.
- Refresh retains downloaded entries for seven days from their local arrival,
  keeps loaded pagination, and writes only new or changed fetched headers.
  Existing bodies and files remain untouched by header refresh. Visible-list
  grouping/filtering is reused until its inputs change.
- OAuth shutdown drains complete credential requests. Local storage failures and
  obsolete rejected refreshes no longer incorrectly demand reconnect. The Swift
  client distinguishes Outlook's known mailbox-connection refusal from rejected
  credentials. The overall intermittent Outlook issue remains unconfirmed.
- The Inbox notification-enable prompt is removed; account notification settings
  remain available. Unused diagnostic arguments and test scaffolding are removed.

- Message rows own their height measurements and reuse prepared sender, preview
  and date text while scrolling. Unchanged Inbox prefetch lists skip repeated
  admission scans while preserving pause/resume and new-snapshot handling.

## Validation

The consolidated source passed **869 JavaScript and 44 Python tests**. The
original Swift IMAP/SMTP implementation passed **152 tests across 39 suites**
after the authentication-response correction; later changes are ArkTS-only.
The signed ARM HAP compiled and source/native-library parity checks passed.
It was installed in place on Pura X, preserving app/storage identities and
leaving the app closed. Device latency and Outlook connectivity remain unverified.
See [incremental cache evidence](incremental-mailbox-refresh.md) and
[Outlook investigation](outlook-reopen-investigation.md), and
[scrolling work counts](inbox-scroll-work.md).

The synthetic TLS benchmark measured approximately 33% less multipart download
and assembly time with 50 ms response delays and identical HTML output. This is
not a live Outlook or device timing measurement. Intermittent live Outlook
authentication refusals remain unresolved; the live receive test was blocked by
IMAP authentication. See [fetch evidence](mime-fetch-batching.md),
[foreground caching](foreground-inbox-cache.md), and
[Outlook test limitations](outlook-html-mail-tests.md).

## AppGallery artifact

Build with `scripts/build-release --appgallery --no-zip`, then sign with the
existing matching AppGallery release key, certificate and profile. The upload
artifact is `dist/D-Mail-1.0.5-arm64-v8a-appgallery-signed.app`. Its adjacent
`*-signed-verification.json` records the exact source commit, package hashes,
release metadata and completed signature/profile verification. Source and legal
notices remain in the companion unsigned-artifact directory. No ZIP is created.

The registered identity stays `some.DMail.hamorny`; the separate development
identity and saved accounts are preserved. Gmail browser sign-in remains disabled
with app-password guidance. This consolidated release includes the Outlook,
retention and scrolling follow-ups. The signed verification sidecar identifies
the exact build commit and package hashes; use the newly generated signed APP.
Store upload remains user-operated. Huawei review acceptance requires uploading
the package and rerunning its checks.
