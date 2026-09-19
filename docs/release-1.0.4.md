# D-Mail 1.0.4

Version **1.0.4**, code **1000004**, replaces the rejected 1.0.3a version name.
The Connect fix is unchanged; only release naming and documentation changed.

The account setup Connect button stays enabled, using white text on the existing
blue primary-button background. Tapping an incomplete form opens a native dialog
asking for the email account details, in English or Simplified Chinese. JMAP
asks for its server address and token. Missing details, invalid IMAP email and
unavailable account storage cannot start a connection. The existing busy guard
prevents duplicate connections.

This addresses the low-contrast Connect button reported in the supplied Huawei
0.1.11 cloud-test screenshot (1.89:1). The explicit foreground/background colors
have approximately 5.55:1 contrast in both themes. It does not establish the cause
of any other current upload or review failure. AppGallery must rerun its checks.

The AppGallery package uses `some.DMail.hamorny` and the matching release
certificate/profile. Gmail browser sign-in stays disabled with app-password
guidance. Native mail, Markdown/math, storage and background behavior are unchanged.
Use `scripts/build-release --appgallery --no-zip` for standalone artifacts
with matching source and notices in a directory.

The unchanged application code passed all 786 JavaScript and 40 Python host
tests in 1.0.3a, including synthetic connection validation and release-package
checks. Version 1.0.4 rebuilds and verifies the package with the new name.
The signed artifact manifest records the completed build and signature checks.
No store upload, device installation or production launch is part of this change.


## Subsequent local Outlook follow-up

The transient OAuth-error classification correction was applied to this `main`
baseline and installed as an in-place 1.0.4 update on Pura X at the user's request.
The existing Connect-button changes remain included. See
[Outlook investigation and corrected installation](outlook-message-failures.md).
This does not update the previously generated AppGallery release artifacts or
establish a fix for the reported message-specific download failures.

The subsequent user-requested Pura X diagnostic update remains 1.0.4 and displays
`1.0.4-download-log-1` in Settings. See [download diagnostics](download-diagnostics.md)
for bounded private logging, export controls, validation and lifecycle limits.

The comprehensive follow-up replaces that diagnostic variant with
`1.0.4-download-log-2-detailed`, retaining package version 1.0.4. It adds exact
rejection conditions, safe parser/transport detail, anonymous retry correlation,
failure retention and late-cleanup capture. See the same diagnostic record.

## Local Outlook body follow-up

The second detailed diagnostic upload identified complete body transfers rejected
because `1.MIME` was absent. The local main follow-up requests the message HEADER
for singlepart roots, retaining version 1.0.4 and detailed logging. See
[the diagnosis, regression and installation record](outlook-singlepart-header-fix.md).

The user confirmed that correction and then requested active Inbox prefetch
while the app is open. The current local build is
`1.0.4-download-log-4-inbox-cache`, still package version 1.0.4. See
[foreground Inbox caching](foreground-inbox-cache.md).

The subsequent login-rejection follow-up shares a bounded original Swift read
session between foreground Inbox pages and bodies. It retires queued requests
after failure without replay and preserves foreground prefetch and HTML behavior.
See [the read-session evidence](imap-read-session-follow-up.md).
