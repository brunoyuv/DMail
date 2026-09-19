# Gmail outgoing settings in 1.0.4

The user reports an existing app-password Gmail account whose outgoing-server
sheet now opens with blank fields. Sending previously worked; the onset is
unknown. No production account storage was accessed during this investigation.

The Google browser-login build flag does not gate the outgoing-server sheet or
delete SMTP credentials. The SMTP Asset alias and saved-account identity are
unchanged. The existing reader returned empty settings both when no record
existed and when an Asset result contained no secret. The latter is now a read
error. Malformed stored settings also produce an error rather than a usable
blank form. An explicit retry reloads unavailable settings without rewriting
them. This does not establish why this device's record became unavailable.

For an actually absent record, the outgoing sheet now offers **Use saved Gmail
login** on password accounts at the exact registered Gmail IMAP endpoint. The
action reads that account's protected incoming Basic login and proposes
`smtp.gmail.com:465` with SSL/TLS, its actual login name and app password. It does
not substitute the display email address, contact a server or write settings.
The user reviews the populated form and presses **Save** before sending.
Existing/custom SMTP records take precedence, and corruption or a storage error
cannot trigger recovery. Google browser sign-in remains disabled.

Account ownership is checked around credential waits. Late recovery and save
completions cannot replace another account's editor or unlock its pending save.
Fresh initialization clears stale editor fields. Temporary credential buffers
are cleared; no credentials, provider responses or account identifiers are
added to diagnostics. English and Simplified Chinese strings are included.

Validation uses synthetic account/Asset fixtures and the actual shipping store
and composer methods. It covers true absence, read failures, malformed records,
custom settings, bound Gmail recovery, explicit Save, removal/replacement races
and late UI completions. All 853 JavaScript and 44 Python tests pass. The signed
ARM64 development build remains 1.0.4
(1000004), with build marker `1.0.4-outlook-auth-gmail-smtp`. It includes the prior
Outlook authentication follow-up. Installation, device rendering and live Gmail
sending are not part of this validation. See
[gmail-smtp-recovery-validation.json](gmail-smtp-recovery-validation.json).

Google documents authenticated SMTP and app-password use in its
[mail-client setup guidance](https://support.google.com/mail/answer/7104828?hl=en).

The later [IMAP greeting correction](imap-greeting-fix.md) includes this SMTP
recovery in the newer signed development artifact with marker
`1.0.4-imap-greeting-smtp`. The original artifact above remains archived locally;
the newer combined build is now installed in place on Pura X, with storage
identities preserved and no production launch. See
[installation evidence](imap-greeting-installation.json).
