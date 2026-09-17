# D-Mail 1.0.3a

Version **1.0.3a**, code **1000004**, follows 1.0.3 without rewriting history.

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
The release builder accepts letter-suffixed version names and `--no-zip` exports
standalone artifacts with matching source and notices in a directory.

All 786 JavaScript and 40 Python host tests passed, including synthetic
connection validation and release-package checks.
The signed artifact manifest records the completed build and signature checks.
No store upload, device installation or production launch is part of this change.
