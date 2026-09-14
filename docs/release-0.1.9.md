# 0.1.9 — unread indicators and new-mail banners

Unread mail now has red indicators in the account header, account picker and
mailbox list, plus a launcher badge. Indicators use current downloaded mailbox
membership and pending read/unread/archive actions, so they work from the cache
without extra server requests. The launcher value is a presence indicator (1 or
0), not a claimed total of unread mail on the server. The system controls its
visual badge style. Existing blue unread bars and tablet split navigation remain.

A confirmed new unread message prepended to the cached Inbox shows a generic
foreground banner even without OS notification permission. Initial loading,
read-flag changes, deleted messages exposing older rows, and a changed UID epoch
do not trigger this banner. Dismiss leaves the reader/composer alone; tapping
uses the existing account-specific notification route and preserves an active
draft. Duplicate cache/notification arrival notices are grouped.

The Inbox offers an initial Enable action for system notifications. A deliberate
account disable is respected. Settings shows available system permission and
channel status, opens HarmonyOS notification settings directly, and provides an
explicit local test-notification button. The button does not contact a mail
server or enable background access. API 24 devices lack the newer separate
banner/badge status fields; an unavailable status is not treated as blocked.

System alerts use the social-communication channel and permit repeated arrival
alerts. Existing user channel settings are preserved. Notifications have generic
content and opaque account routing, with no address, sender, subject or body.
The app must be allowed to publish notifications, and system banners/badges must
be enabled in HarmonyOS settings. Foreground banners do not change background
execution limits or introduce a relay.

## Validation

All 225 host tests passed. The bounded native test passed in 19.1 seconds:
header/account/mailbox dots, read/unread changes, visible permission entry,
banner dismissal preserving Compose, OS permission, banner-capable social
channel, private publication/cancellation, badge 1→0 and scheduler registration.
The fixture made zero mail-service calls. The emulator stopped, the isolated
fixture was removed and its screen profile was restored.

Signed ARM, x86 production and isolated test builds passed. Both Pura X and
MatePad received verified in-place 0.1.9 upgrades with accounts preserved and
production left closed. See the [validation record](../port/mail-corpus/release-0.1.9-validation.json).
