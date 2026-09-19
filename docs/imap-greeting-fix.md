# IMAP greeting follow-up in 1.0.4

The user reports intermittent Outlook connection/authentication failures after
successful browser sign-in, both when adding an account and after it is saved.
The isolated account comparison and its limitations are recorded in
[the test account validation](outlook-test-account-validation.json).

A separate synthetic TLS test reproduced a connection-order defect in the
original Swift client's port: `connect()` sent CAPABILITY as soon as the TCP
channel existed, without waiting for the IMAP server's initial greeting.
With a 350 ms delayed greeting, a permissive peer accepted the early command,
but a peer refusing commands before its greeting closed the connection and the
client failed. A peer that omitted its greeting entirely could also get the
old client to send synthetic credentials and finish authentication. A PREAUTH
greeting was ignored and followed by an inappropriate AUTHENTICATE command.

The [IMAP connection/state sequence](https://www.rfc-editor.org/rfc/rfc3501.html#section-3)
uses the greeting to establish the initial protocol state. D-Mail's saved
account model requires authentication with the selected account's credentials;
an unsolicited PREAUTH state cannot establish that binding.

The explicit `initial-greeting.patch` installs the port-owned
`InitialGreetingHandler` alongside the original client's TLS/IMAP decoder before
network input can arrive. Its future retains even an immediate greeting until
`connect()` waits for it. Only a valid OK greeting permits CAPABILITY. BYE,
PREAUTH, malformed or missing greetings close the connection without commands
or credentials. Cancellation closes the channel and preserves CancellationError;
transport failure and the existing connection deadline also settle the wait.
Completion/removal cancel the timer and settle the promise only once.

TLS verification, command/authentication deadlines, one attempt, original Swift
protocol code, upstream hashes, saved identities and version 1.0.4 (1000004) are
preserved. No greeting result causes an automatic authentication retry. Host and
native builds use the same staging patch and handler.

The synthetic defect is confirmed. Its contribution to the user's intermittent
Outlook failures remains unproven: the earlier tagged authentication refusals
and the later independent-client timeout do not establish their cause.
The shared OAuth token audit found no demonstrated field or byte corruption,
including printable punctuation and maximum-sized synthetic tokens.

Validation passed all 147 Swift host tests (37 suites), including 20 focused
connection/authentication tests. Seven synthetic TLS before/after cases confirm
that no command precedes the greeting, the strict delayed-greeting case now
succeeds, both SASL-IR and continuation authentication still work, and PREAUTH or
missing greetings fail before credentials. Cancellation returns promptly and
settles the timer/promise once. All 853 JavaScript and 44 Python tests also pass.
No further live-account retries were used for these checks.

The combined signed ARM64 development package was rebuilt with the existing
Gmail SMTP recovery and the new diagnostic marker `1.0.4-imap-greeting-smtp`.
It remains 1.0.4 (1000004), preserves the development identity and logging
preference. It is now installed in place on Pura X at the user’s request. See
[the validation record](imap-greeting-validation.json) for package hash and checks.
The signed HAP contains the current source/native libraries and the expected
`org.thunderbird.harmony.dev` identity. The installer confirmed success, the
signed input hash and installed version were checked, and app/storage identities
remained unchanged. Production was not launched and its process was absent after
installation. No real mailbox was accessed. The installed HAP was not read back;
prior OS access attempts were denied. See [installation evidence](imap-greeting-installation.json).
AppGallery packaging, MatePad update, commit and push were not performed.
