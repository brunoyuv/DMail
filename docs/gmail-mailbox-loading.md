# Gmail mailbox loading after sign-in

The user reported the same inbox-loading failure with OAuth and an app password.
Their authorized error-only screenshot showed the generic connection message.
An allowlist-only scan of existing device logs showed a completed folder LIST
followed by STATUS without completion; no log arguments or message data were
retained. This narrows the failing path but does not establish Gmail's precise
reason for rejecting or failing that STATUS request.

The adapter previously aborted the entire folder load if any STATUS request
failed. It requested unused extended status attributes through the upstream
default. The adapter now requests only MESSAGES and UNSEEN, preserves successfully
listed folders when optional counts fail, and stops further count requests after
the first failure or five-second scheduling budget. A count request already in
flight retains the client's existing command timeout. Cancellation is respected.

Unknown counts are represented explicitly and their badges are hidden, including
after cache reload. Zero is shown only when the count is known. Opening an account
clears its old paging cursor. Load more requires a selected folder. Pull-to-refresh
retries folder discovery and opens Inbox when the first load failed.

All protocol work still uses Thunderbird's original Swift IMAP client. Regression
fixtures cover minimal status attributes, rejected and disconnected status queries,
continued message loading, and a native pull gesture recovering a failed LIST.
The user's real mailbox tests remain user-operated.

Validation on 2026-09-14: 65 host checks passed, plus four native loading/UI
checks and seven native OAuth mail checks. The UI test caught a remaining
refresh-enabled guard after its lock-screen setup was corrected; the final run
passed with that guard fixed. Signed ARM source/library parity passed. Installation
on Pura X succeeded with saved accounts retained and no production app launch.
The emulator exited. Live Gmail reading remains for the user to verify.
Evidence: `port/swift-imap/mailbox-loading-validation.json`.
