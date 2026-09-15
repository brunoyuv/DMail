# 0.1.7 — mail notifications and checking frequency

Mailboxes → Settings offers New mail alerts for each account. Enabling it asks
for HarmonyOS notification permission. Alerts start with the next detected
arrival; existing unread mail establishes a silent baseline. Alerts show only
“New mail” and “Open inbox,” without message text or the account address. Tapping
an alert opens that account’s inbox after an active composer has been closed.

While the app is open, supported IMAP accounts use Thunderbird’s original Swift
IMAP client to maintain an IDLE connection. The server announces changes over
that connection. Quiet monitoring does not repeatedly request mailbox contents.
The connection closes when the app moves to the background. Unsupported or
failed IDLE connections fall back to checks every 5, 15, 30 or 60 minutes,
according to the account’s setting.

Background checks use a persisted HarmonyOS WorkScheduler job. The account’s
requested interval can be 2, 4, 6 or 12 hours. These are scheduling preferences,
not guaranteed delivery times: HarmonyOS may defer a job according to system
conditions. WorkScheduler requires a repeat interval of at least two hours and
limits each execution to two minutes. The app stops starting new account checks
after one minute, reserving time for completion and cleanup.

IMAP checks compare UIDVALIDITY and UIDNEXT. An unchanged inbox needs no message
fetch. When the inbox changes, the check requests at most 50 recent UID/FLAGS
records and never downloads message headers or bodies. JMAP accounts use a
bounded metadata page and a conservative received-time checkpoint. Existing
message and picture caches are not pruned or replaced by notification checks.

Opting in creates a separate incoming-mail credential entry that is accessible
after the device’s first unlock following a restart. Ordinary foreground
credentials retain their existing device-unlocked protection; SMTP credentials
are not copied. Turning alerts off removes the background credential entries.
OAuth refreshes share a lease across foreground and background execution so the
same refresh token is not rotated concurrently.

One durable lease prevents overlapping foreground and background checks. Failed
checks back off, server events survive a busy check, and a persistent notification
outbox retries failed alert publication. Account revisions prevent stale work
from publishing after alerts are disabled or the account is removed.

This release uses direct mail-server connections and local OS notifications.
The repository must work with users’ existing mail servers without a privately
operated relay. It therefore has no relay endpoint, relay credentials or Huawei
Push Kit registration dependency. Background notification timing remains subject
to HarmonyOS scheduling; the app does not promise instant alerts while suspended.

## Platform references

- [IMAP IDLE, RFC 2177](https://www.rfc-editor.org/info/rfc2177/)
- [WorkScheduler interval requirements](https://github.com/openharmony/docs/blob/master/en/application-dev/reference/apis-backgroundtasks-kit/js-apis-resourceschedule-workScheduler.md#workinfo)
- [Deferred background work and execution limits](https://github.com/openharmony/docs/blob/master/en/application-dev/task-management/work-scheduler.md)
- [Continuous background task restrictions](https://github.com/openharmony/docs/blob/master/en/application-dev/task-management/continuous-task.md)
- [Huawei Push Kit integration](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/push-kit-introduction)

## Validation and installation

- All 195 host tests passed, including notification scheduling, background
  credential access, service lifecycle races and JMAP timestamp boundaries.
- Four focused Swift inbox-check tests and three Swift IDLE lifecycle tests passed.
- Three bounded HarmonyOS native gates passed: persistent IDLE and server events;
  metadata-only inbox checks; notification permission, private alert publication
  and cancellation, and persisted two-hour work registration/removal.
- The native gates used isolated synthetic fixtures. The scheduler gate verified
  registration; it did not wait two hours for a system-scheduled callback.
- Final ARM signed and x86 production builds passed. Both devices received the
  verified signed ARM artifact as an in-place upgrade to 0.1.7 (100007).
  Pura X VDE-AL00 and MatePad MRO-W00 bundle metadata matched the release.
- Saved accounts were preserved and production was not launched. The isolated
  fixture was removed; the emulator stopped and its screen profile was restored.

The final JMAP timestamp refinement was covered by host tests and both production
builds after the native gates. It adds no server requests. Incomplete or overflowing
groups of messages with identical received times remain conservative; an exact
JMAP changes stream is not implemented.

Detailed results are recorded in
[the release validation record](../port/mail-corpus/release-0.1.7-validation.json).
Automated tests use synthetic mail only; production mail remains user-operated.
