# Foreground Inbox caching on 1.0.4

After confirming that the Outlook singlepart-header correction fixed the email
failure, the user explicitly selected downloading the active Inbox's emails in
the background while the app is open. The main 1.0.4 follow-up is identified in
Settings and exported diagnostics as `1.0.4-download-log-4-inbox-cache`.

InboxPrefetch downloads missing bodies and prepares their HTML with the existing
MailMessageLoader. The reader opens the same durable body/document cache without
another body download or HTML preparation. Previously downloaded bodies are
skipped using a metadata-only lookup, including usable partial and attachment-only
messages. The existing seven-day retention remains unchanged. Closing the app
stops prefetching; it does not erase downloaded mail.

The worker starts with the active Inbox's known headers, then follows its later
pages with no first-page or fixed message-count cutoff. Extra page headers are
saved without replacing the visible list, scroll position or navigation cursor.
Mailbox snapshot changes retire old traversal results. Repeated/non-advancing
page cursors stop traversal; a changed server snapshot restarts from the head
after cooldown. Other accounts and folders have no prefetch context.

## Ownership and pacing

Only one automatic operation runs at a time through AutomaticMailWork, retaining
its minimum three-second gap after completion. Prefetch also shares the reader's
body lane. Selecting a message pauses prefetch: an already-started body may
finish and save under its captured account, after which the reader reuses that
save. Cached reads bypass queued network work.

No new prefetch operation starts while the app is backgrounded, both Inbox and
reader are hidden, the composer is open, a foreground load/mutation is busy, a
scroll/swipe interaction is active, or the existing thermal policy pauses work.
The current Inbox can continue prefetching while an already-loaded message is
visible. Lifecycle updates and thermal callbacks resume queued work without an
idle polling timer. Closing releases the thermal subscription and pending timer.
Both IMAP and JMAP recheck the captured owner after an asynchronous credential
lookup, before entering the native core.

A cancelled or timed-out loader retains ownership until its underlying work
drains. This prevents a deadline from starting an overlapping automatic request.
Failed messages remain incomplete and available for explicit reader Retry; the
same worker context does not repeatedly download them on every wake. Other work
backs off from one minute up to ten minutes after failures. Authentication
rejection stops the context until a new client context is created through
reconnection/account reopening. Idle, completed and authentication-blocked queues
have no retry timer.

This does not enable the legacy durable all-account MailBodySync worker or OS
background mail-body downloads. Remote pictures retain the progressive reader
path, and attachment bytes remain on demand. Prefetch does not mark mail read,
send mail, show reconnect UI, alter credentials, or publish an updated reader.
Detailed logging distinguishes `prefetch` from explicit `reader` attempts and
continues excluding message content and credentials.

## Validation

The final host suite passes **812 JavaScript and 40 Python tests**. Fourteen new
prefetch tests use the actual loader with synthetic stores and a controlled
automatic-work clock. They cover pacing, already-cached bodies, 105-message
pagination, pause/resume, clicking during download, original-account saves,
cooldowns, authentication rejection, stale/non-advancing cursors, thermal and
close cleanup, and retaining the lane past a UI deadline. A shipping-component
test covers Inbox/reader visibility, composition, foreground and interaction
wiring. IMAP and JMAP tests cover cancellation during credential lookup.

The ARM64 core and signed HAP build with the pinned SDK 26 toolchain. Signed
verification checks production source parity, library hashes, package identity,
version 1.0.4 (1000004), the new build marker and prefetch code in bytecode. The
earlier 46 focused Swift tests and user confirmation cover the included Outlook
fix. Automated tests used no production mailbox or physical mail UI. The emulator
remained stopped and MatePad was untouched.

See [the validation and installation record](foreground-inbox-cache-validation.json).
Local evidence and the signed package remain under ignored
`.tools/inbox-prefetch-104/`. No commit, push or public release was performed.
