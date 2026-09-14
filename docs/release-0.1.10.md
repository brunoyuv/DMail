# 0.1.10 — sending and connection recovery

Gmail sending could fail before reaching SMTP when an inbox check was already
refreshing the Google access token. Send now waits for that refresh to persist
its result and reuses it, with a bounded wait and no competing token request.
Gmail OAuth also accepts its documented SSL/TLS port 465 as well as STARTTLS
port 587, while retaining exact provider-host and login checks.

Failed drafts retain a safe diagnostic such as `AUTH/network` or `SMTP/network`,
including after reopening the composer. Only fixed stages and allowlisted codes
are stored or displayed. Raw server replies, account data and tokens are excluded.
An uncertain delivery still requires explicit user action; this update does not
automatically repeat a submission or Sent-folder append.

The reader now offers Retry after a failed body download or saved-copy fallback,
while retaining the actual connection or sign-in error. Successful downloads are
shown before optional folder-permission checks. Normal body retries do not fetch
extra folder metadata. A changed IMAP mailbox epoch leads to a folder refresh
instead of repeatedly requesting an obsolete message ID. Unread mail is marked
read after a successful retry when permissions allow it.

Saved Google and Outlook OAuth accounts have Reconnect under Mailboxes → Accounts,
and an authentication error offers it directly. Reconnect verifies the saved
server login before replacing credentials, retains the account ID and encryption
key, and preserves mail, drafts, sender preferences, SMTP settings and notification
opt-in. An older in-flight refresh cannot overwrite the new sign-in. The current
reader resumes after a successful reconnect; another account's view is preserved.

The “Saved copy” timestamp identifies a cached download; it does not establish
that the copy expired or why the connection failed. Existing seven-day retention
is measured from download time, independently of the message's age.

## Validation

All 255 host tests passed, including token-refresh overlap, SMTP endpoint binding,
persistent safe diagnostics, reconnect cancellation/identity/removal races,
old-body retry, retained cached bodies and stale mailbox IDs. The signed ARM, production x86 and isolated fixture builds passed. Native Swift
library bytes match the previously validated release.

The bounded native UI check passed in 20.7 seconds: a failed old-message body
request exposes Retry, retry downloads and caches the body, offline reopen uses
that cache without another request, another downloaded body is preserved, and
saved OAuth Reconnect is visible/enabled without opening a browser. Exactly two
in-memory body requests occurred, with no other mail-service calls. The wrapper
ran isolated-app cleanup, restored the screen profile and stopped the emulator;
a separate process check confirmed it stopped.

Both Pura X and MatePad received verified in-place 0.1.10 upgrades. Accounts were
preserved and production was not launched. See the
[validation record](../port/mail-corpus/release-0.1.10-validation.json).

Real Gmail retries remain user-operated; the reported provider failure has not
been reproduced using the user's account.
