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
