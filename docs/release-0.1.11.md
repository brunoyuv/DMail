# 0.1.11 — unread totals and muted accounts

The launcher badge now uses the combined unread Inbox total for accounts with
New mail alerts enabled. It no longer converts every nonempty Inbox into the
number 1, and a muted account no longer contributes to the app badge or shows
foreground arrival banners. Inbox browsing and automatic row updates continue
for muted accounts. In-app unread markers still identify unread mail normally.

Counts come from full server totals, independently of the bounded message list.
IMAP reads MESSAGES/UNSEEN through one optional STATUS command on the existing
authenticated checking connection. JMAP uses Mailbox/get and reuses its initial
Inbox discovery response. Count metadata failures preserve successful arrival
detection and the previous known total. The optional IMAP count command has a
two-second deadline, so a stalled metadata response cannot discard arrivals
already detected. No body download or additional IMAP
connection is introduced for counting.

Exact totals persist in the encrypted account database. New local read/unread and
archive actions project their count changes immediately, then persist confirmed
changes atomically with cached flags and membership. Durable revisions prevent
a delayed count response from overwriting a newer local operation or a changed
notification preference. Reopening works with the last known totals. When an
enabled account has no trustworthy total yet, the app waits for a successful
check and clears the launcher badge rather than presenting a partial downloaded-
message count as a total. Counts reflect the last successful check with pending
local changes applied. Changes made in another mail client can temporarily make
cached flags disagree with the count; the next successful check reconciles it.

Foreground and background badge updates use the same account filter and stored
totals. Notification publication does not increment the badge or replace it with
1. Disabling/removing an account updates the badge and dismisses its foreground
banner; late notification completion cannot restore the muted banner. HarmonyOS
controls badge presentation and displays counts over 99 as 99+.

The native storage gate exposed a read-after-write ordering error: a database
reader can still see the committed revision while a writer has incremented it
inside a transaction. The count guard now derives the next revision from the
value read before the update. A separate-reader SQLite regression reproduces
the old rejection and verifies the correction.

The same ordering error affected notification-check and OAuth-refresh lease
acquisition. Their conditional writes remain atomic; ownership is now read after
commit. Three separate-reader regressions reproduce the previous skipped check
and token-refresh failure, then verify ownership isolation and one successful
synthetic token refresh. This does not establish the cause of a particular real
provider error. No real account retries or messages were used.

## Validation

All 289 host tests and six focused Swift tests passed. The native IMAP gate
passed in 4.183 seconds, covering 13 synthetic sessions, eight bounded UID/FLAGS
fetches, 12 count STATUS commands and one UIDNEXT fallback; no headers or bodies
were fetched. The corrected native badge gate passed in 12.524 seconds: exact
totals persisted through reopen, the OS badge retained 145 through notification
publication, muting reduced it to 8 then 0, and competing notification-check
owners remained isolated. It made no mail service calls.

The first badge gate failed before publication because the revision guard was
stale; its correction and the related lease fixes were rebuilt and verified by
the successful final gate. Both bounded wrappers stopped the emulator and
restored its profile. Automated checks used synthetic accounts and messages only.

HAP builds now use Command Line Tools 26.0.0.821, Hvigor 6.26.4 and SDK
26.0.0.105. The compile SDK is 26; target and minimum API remain 22. Swift and its
dependencies retain the existing API 22 native toolchain. The new HAP toolchain
uses its own build cache and preserves local signing when staging projects.
Production x86, signed ARM and both isolated test HAPs built successfully. Their
metadata confirms compile SDK 26.0.0.105 with minimum and target API 22; imported
Swift library hashes match the staged libraries. The API 22 emulator executed
the SDK 26 build successfully. Three compatibility warnings for Circle.fill
refer to SDK 26's added ColorMetrics overload; these call sites use the string
color overload already present in SDK 22.

Version 0.1.11 (100011) is installed and metadata/hash-verified on Pura X
VDE-AL00 and MatePad MRO-W00. Both used the same signed HAP and in-place upgrades;
saved accounts were preserved and production was not launched. A separate native
process check confirmed the emulator stopped. Full evidence is recorded in
[release-0.1.11-validation.json](../port/mail-corpus/release-0.1.11-validation.json).
