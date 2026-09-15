# 0.1.8 — automatic inbox updates

New-mail detection in 0.1.7 updated notification checkpoints and could publish
an OS alert, but never refreshed the inbox's cached headers or visible rows.
Pulling down to refresh worked because that separate path fetched the message
list. Version 0.1.8 connects foreground server events to the inbox update path.

The selected account is monitored while the app is open even if New mail alerts
are off or OS notification permission is denied. Supported IMAP servers reuse
the existing original Swift IDLE connection. Readiness and subsequent arrival
events request a quiet Inbox header refresh independently of unread counts and
notification publication. Unsupported IMAP and JMAP servers use the selected
foreground fallback interval. Background registration failure does not block
foreground monitoring.

Update hints are retained per account and coalesced. Quiet updates preserve the
current reader, draft, search/filter selection, downloaded bodies and already
loaded older rows. They do not fetch the companion Sent folder, list mailboxes,
or download message bodies. Navigation and operation revisions guard against
stale responses after account switches, pagination and flag changes.

Foreground monitoring stops when the app goes into the background. Queued UI
updates wait until it returns. This fixes the open-app refresh defect; it does
not change the OS-deferred background interval or add a private relay.

## Validation and installation

The bounded native UI test passed in 16.3 seconds. Three consecutive arrival
hints produced one Inbox request and a new visible row without a pull gesture.
A second arrival updated the cached list while preserving the selected message
and its original body-retention timestamp. The fixture made exactly two Inbox
page requests, no body/mailbox-list/Sent requests, and left alerts disabled.
Foreign-account hints did not refresh the active Inbox.

All 204 host tests passed, including four focused regressions for stale responses,
reader/cache retention, deferred arrivals and shared in-flight refreshes.
Final signed ARM, x86 production and isolated x86 test builds passed. Pura X
VDE-AL00 and MatePad MRO-W00 received in-place upgrades to 0.1.8 (100008), verified
against the signed artifact hash. Saved accounts were preserved; production was
not launched. The isolated fixture was removed and the emulator stopped with
its original screen configuration restored.

Host results and installation evidence are recorded in
[the release validation record](../port/mail-corpus/release-0.1.8-validation.json).
