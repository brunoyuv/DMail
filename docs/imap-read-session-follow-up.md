# 1.0.4 foreground IMAP read sessions

The latest uploaded diagnostic export is from `1.0.4-download-log-4-inbox-cache`.
Its retained history includes older failures from before the user-confirmed
singlepart HTML fix. Those historical failures are not evidence of a regression.

The new window contains nine completed native page/body attempts over roughly
54 seconds: two page requests rejected during XOAUTH2 authentication, then a
successful page request; three successful body reads; two more successful page
requests and one page timeout after authentication succeeded. The server's
rejections are tagged NO without an allowlisted response code. Up to three native
requests overlapped. A second login began about 200 ms after the preceding failed
request completed. This proves rejections and overlapping work, but does not
establish Microsoft throttling, a provider quota or an overall rejection rate.
Logging was disabled at export and no prefetch events are present, so this is an
incomplete sample and cannot attribute the overlap to prefetch.

Previously each foreground page/body request authenticated a new Swift client.
The follow-up serializes those reads per NativeImapClient and supplies a private
UUID to the existing original Swift read-session pool. Pages and bodies share
one connection, still bound to exact endpoint, account, login and current
credentials. Credential resolution happens on admission; rotation closes the
old lease before a new one is used. Native sessions retain their 15-second idle,
60-second lifetime, 16-read and four-session pool limits. Each operation reselects
and verifies its own mailbox/UID epoch. Mutations, IDLE and SMTP stay separate.

A failed native request closes its lease and rejects requests already queued in
that generation with the original failure, without another login or replay.
Later calls may create a fresh lease. Backgrounding, account switching/removal
and component teardown retire queued reads and release the connection after
accepted work drains. Foreground Inbox prefetch and its existing pacing/backoff
remain enabled. A successful header request whose optional preview timeout
closed the socket cannot retain that dead socket for the next body read.

No HTML acceptance rules were tightened. The root HEADER/singlepart BODY[1] fix,
MIME parsing, rendering, size bounds and cached bodies remain intact. Diagnostics
add only allowlisted session-created/reused/discarded reasons; no credentials,
server responses, session UUIDs or mail content are exported. The saved logging
enabled/disabled preference is respected.

Validation and installation results are in
[imap-read-session-validation.json](imap-read-session-validation.json).
Tests use synthetic loopback TLS fixtures and host mocks; production mail and UI
are not accessed. These tests demonstrate connection reuse and failure handling,
not that Microsoft will accept every future login.

The signed `1.0.4-download-log-5-read-sessions` build is installed in place on
Pura X. App/storage identities and version 1.0.4 (1000004) were verified;
production was not launched. All 817 JavaScript, 40 Python and 56 focused Swift
tests passed. The ARM64 build, shipping source parity and signed input hash were
verified. No emulator was used, and MatePad was unchanged.
