# Intermittent Outlook authentication in 1.0.4

The user reports browser sign-in completing followed by `authenticationRequired`
when adding a personal Outlook account. The failure occurs in both the official
AppGallery distribution and the installed development build. Multiple attempts
eventually succeeded, and authentication failures also occur after the account
has already been saved. This is not established as a release-signing defect or
an invalid account configuration.

The actual signed AppGallery HAP was disassembled: its compiled sign-in method,
credentials object, client factory and native request preserve the username and
Bearer token. Native library hashes match the release manifest. The UTF-8 NAPI
bridge preserves the full bounded request, and release obfuscation is disabled.
Synthetic first-add tests execute those production ArkTS methods together for
both current source and the packaged c21edce source. They cover token punctuation,
the maximum accepted token size, one native attempt, and no save after rejection.

The native `authenticationRequired` code previously conflated malformed local
credentials with a rejected IMAP authentication command. An uncoded server NO can
represent a temporary refusal: it is not proof that the user's password or OAuth
grant is wrong. Browser success proves token exchange completed, not that a later
IMAP authentication will be accepted. Existing-account failures can also originate
in refreshing saved OAuth credentials.

A separate saved-account race was reproduced: if a successful reconnect saves
new credentials while an older refresh is pending, the refresh correctly refuses
to overwrite the newer envelope but incorrectly reports authentication failure.
The superseded refresh now reports the existing network outcome, leaving the
new credentials intact and making no retry. This avoids a false reconnect prompt;
it does not explain first-time account addition. Account removal and actual
credential rejection keep their authentication classification.

The port now explicitly repeats the already requested Outlook IMAP, SMTP and
offline-access scopes when redeeming a Microsoft code or refreshing its token.
This follows the [Microsoft mail guidance](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth).
Microsoft's [general code-flow documentation](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
allows scope omission, so this is a compatibility improvement, not a confirmed
fix for the intermittent rejection. Google/custom registrations are unchanged.
Tokens remain opaque; no JWT assumptions or required response-scope field were
introduced. Pinned upstream code and hashes are unchanged.

An allowlisted error-stage detail distinguishes local `credentials`, IMAP
`server`, and OAuth `refresh` failures without enabling or recording logs. The
existing error classification, saved account, refresh leases and token-rotation
guards are preserved. Rejected IMAP operations and token POSTs are not retried
automatically. Native transport and post-authentication CAPABILITY failures keep
their existing network classification. No provider text, token or account detail
is added to the UI.

The live cause remains unconfirmed. The next naturally occurring failure can
provide the stage without repeating browser sign-in solely for diagnosis. A
server-stage failure alone still does not establish throttling or a provider quota.


Validation: all 828 JavaScript and 44 Python host tests pass, together with 37
focused Swift OAuth/token/TLS tests. The ARM64 Swift core and signed development
HAP rebuilt with CLI/SDK 26; staged source and native library parity checks pass.
The package remains version 1.0.4 (1000004), with diagnostic build marker
`1.0.4-outlook-auth-details`. See
[outlook-authentication-validation.json](outlook-authentication-validation.json).
This follow-up has not been installed, published or committed. The existing
AppGallery package is unchanged. The live intermittent failure remains unverified.

On 2026-09-19 the user supplied a dedicated personal Outlook test mailbox and
completed Microsoft browser sign-in personally. An isolated host probe linked
the production Swift OAuth bridge and original Swift IMAP client, with protocol
logging disabled. Both token exchanges succeeded; the IMAP AUTHENTICATE command
was rejected with `authenticationRequired/server`. The first attempt preceded
enabling IMAP on the new mailbox; the second followed the user's confirmation
that IMAP was enabled. The reason for the second refusal is not established;
these results do not identify the cause of the original account's intermittent
failure. No mail was read or sent, no rejected request was retried, and refresh
was skipped after rejection. Tokens remained in memory and the bounded listener
and child process exited. See
[outlook-test-account-validation.json](outlook-test-account-validation.json).


A subsequent comparison used one newly issued token in the original Swift IMAP
client and in Python's independent `imaplib`, once each. Microsoft returned
recognized IMAP and SMTP scopes. Swift reported `networkOrProtocol`; `imaplib`
reported `timeout`. Neither authenticated. This controller did not retain the
exact failing substage, so these outcomes cannot be narrowed to the server
greeting or AUTHENTICATE command. A separate later connection without credentials
completed DNS, TCP, verified TLS, greeting and CAPABILITY in 132 ms. That confirms
the endpoint was reachable during that separate check; it does not establish
where the earlier two connections failed or explain the original intermittent
authentication rejection. No automatic retries, token refresh, mailbox reads or
sends followed this comparison.

The first comparison setup expired before its callback arrived and made no
authentication attempt. It was restarted with fresh state and PKCE. The local
listener now remains available longer for user-operated sign-in and results;
the production ten-minute OAuth session lifetime is unchanged. This diagnostic
setup change does not affect any shipping package. The current combined signed
1.0.4 auth/Gmail SMTP development package and its validation are described in
[gmail-smtp-recovery.md](gmail-smtp-recovery.md). The newer greeting/SMTP build
including these changes is now installed on Pura X; see
[installation evidence](imap-greeting-installation.json).
