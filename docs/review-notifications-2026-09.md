# Notification and Inbox-watch review — September 2026

Reviewed the current source on 2026-09-14 as part of the performance, bug and UI-race review. This record covers notification scheduling, foreground arrival watches, bounded background checks, generic banners and unread-badge coordination. It does not claim measured battery, CPU or temperature improvements. No real account, mailbox, physical device or emulator was accessed for this review.

## Confirmed findings and fixes

All six findings below are fixed in the working tree. Line references describe the resulting source; the regressions exercise the previous trigger and the required behavior.

| Priority | Finding and reproduction | Change and evidence |
| --- | --- | --- |
| P2 | A check stopped while permission, account ownership, credential access or JMAP discovery was awaited could still start another request. A pending alert could also begin publication after cancellation. | [NotificationEngine.ts](../harmony/entry/src/main/ets/mail/notifications/NotificationEngine.ts#L23) rechecks cancellation before publication/lease acquisition/server work. [CheckEnvironment](../harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets#L45) checks cancellation after each prerequisite and before the next JMAP request. Its credential adapter also rejects a delayed IMAP authorization before NativeImapClient can enter NAPI after a stop. Synthetic cancellation at permission, metadata, badge guard, credentials, discovery and page boundaries, plus stalled IMAP watch/check authorization, starts no subsequent request; a durable unpublished notice remains available for the next run. Already-started publication retains its acknowledgement and stale-setting cleanup, preventing duplicate delivery. |
| P2 | A foreground reconciliation captured enabled settings, paused at the OS permission query, and could start one native watch after the user disabled those alerts. A newer reconciliation eventually stopped it, but credential access and connection startup had already occurred. | [MailNotificationService.tick](../harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets#L169) also owns a configuration revision across awaits. The regression disables alerts while permission is blocked and observes zero watch snapshots, credential reads and checks from the obsolete snapshot. Visible-inbox arrival watching remains independent of OS alerts. |
| P2 | An IDLE event retained after a failed check retried the service every ten seconds during persisted network-error backoff. The engine avoided another server request, but each attempt reopened the encrypted store and reconciled the badge. | [The watch retry loop](../harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets#L250) uses the same persisted deadline as [checkIsDue](../harmony/entry/src/main/ets/mail/notifications/NotificationModel.ts#L24). A synthetic 49-second period before the ordinary minute tick had four redundant opens before the fix and zero afterward. Local native snapshots continue; the retained arrival succeeds when backoff expires. Lease contention keeps its ten-second retry. |
| P2 | Every native `EXISTS` event set the arrival flag even when the selected Inbox count had not changed. Repeating `* 81 EXISTS` between snapshots repeatedly requested quiet header refreshes and alert checks. | [InboxWatchChanges](../port/swift-imap/InboxWatch.swift#L10) starts with the EXAMINE count and suppresses unchanged counts. It also decrements its count for EXPUNGE, so a later arrival restoring the old count remains detectable. Native tests cover thirty repeated counts, multiple expunges, restored counts, unknown counts and an empty Inbox. The ready event still requests the resume refresh. |
| P2 | Explicit OAuth reconnect saved new credentials but ordinary settings reconciliation kept an existing watch because its notification-settings revision had not changed. That native session retained its original authorization until disconnect or its bounded renewal. | [credentialsChanged(accountId)](../harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets#L116) invalidates only that account's watch and retry state. The reconnect success path calls it after credential replacement. A two-account regression verifies new authorization and watch identity for the reconnected account, preserving the other session. Ordinary settings rereads and automatic token rotation do not unnecessarily reconnect authenticated sessions. |
| P3 | A same-store burst of thirty badge refresh requests queued thirty OS writes and sixty total-count reads, although all requests were queued before the first one ran. | [MailBadgeService.refresh](../harmony/entry/src/main/ets/mail/notifications/MailBadgeService.ets#L17) coalesces only work that has not started. The burst now uses one write and its two required count reads. Requests during an active OS write still queue a fresh reconciliation; later completed refreshes still write, allowing recovery from badge changes by another process. Failure recovery and mute-during-write tests remain passing. |

The new cancellation, stale-tick, repeated-backoff and badge-burst regressions were run against the previous implementation and failed at the expected observable operation/count, then passed after the corresponding fix. Native state-transition tests exercise the actual helper used by the IDLE event loop. The reconnect regression verifies the explicit success hook's account scope and preserves ordinary authenticated-session reuse.

## File coverage and retained guarantees

| Reviewed production source | Review focus and result |
| --- | --- |
| `mail/notifications/NotificationEngine.ts` | Durable lease, bounded run deadline, per-account revisions, cancellation, failed checks and outbox acknowledgement. Disabled or superseded settings cannot retain a published alert; a stopped unpublished notice is not acknowledged. |
| `mail/notifications/NotificationModel.ts` | Public interval choices, failure backoff, clock rollback, silent baseline, bounded JMAP membership/timestamp checkpoints. The new deadline helper preserves the existing due-check semantics. |
| `mail/notifications/MailNotificationService.ets` | Complete foreground/background lifecycle, watch ownership, configuration changes, permission races, pending events, error/lease retry cadence, visible-account fallback and store cleanup. One-second snapshots read the native event flag; they are not server polls. The ordinary reconciliation interval remains one minute, configured fallback checks remain 5/15/30/60 minutes, and watches stop in background. |
| `mail/notifications/NotificationPlatform.ets` | Permission and slot access, generic notification content and opaque tap route, serialized numeric badge writes, persisted work replacement/restoration. Unchanged jobs are retained; a rejected replacement attempts to restore the prior job. No process-local badge-value cache can prevent repair after another process writes it. |
| `mail/notifications/MailBadgeService.ets` | Full enabled-account total, unknown/error clear, pending local projections, post-write reconciliation, serialization and burst coalescing. No change to the persisted total/revision rules. |
| `mail/notifications/MailInboxUpdates.ets` | Account-local retained revision, foreground state and content-free invalidation bus. A busy or switched UI can still consume its own account's newer revision. |
| `mail/notifications/MailBannerNotice.ets` | Generic content, source/account delivery versions, seven-second coalescing, mute reconciliation and account-specific tap route. Background events do not replay as foreground banners on resume. |
| `mail/MailUnreadStatus.ets` | In-app unread markers for all accounts, pending overlays and cache reads. Header-only cache-read integration and its tests belong to the concurrent protocol/storage review; this file was not edited by this reviewer. |
| `abilities/MailCheckAbility.ets` | A stopped or superseded work generation cancels its check; an older completion cannot stop a newer scheduled invocation. |
| `entryability/EntryAbility.ets` | Foreground/background/window-destruction hooks and opaque notification-route handling. Composer-preserving route navigation remains in the separately reviewed pages. |
| `harmony/entry/src/main/module.json5` | Non-exported WorkScheduler extension, existing Internet permission and main ability declaration; no new background entitlement. |
| `port/swift-imap/InboxWatch.swift` | Entire registry/entry lifetime, ownership, eight-entry bound, immediate snapshots, 25-second readiness limit, 120-second unread lease, 25-minute renewal, IDLE event deduplication and cancellation/cleanup. No global lock encloses network awaits. |
| `port/swift-imap/InboxCheck.swift` | Entire cursor/range/count helper: silent baseline, UID epoch changes, maximum fifty newest UID/FLAGS records, explicit flags, UID deduplication and consistent optional full unread counts. |
| `port/swift-imap/ImapAccountCore.swift` watch/check branches | Native request validation and watch ownership; first-selection watermark, final epoch verification, optional same-session STATUS with a two-second deadline. An optional count failure preserves detected arrivals. The full protocol bridge is covered by the concurrent protocol review. |
| `mail/imap/NativeImapClient.ets` watch/check integration | Cached initial watch request, snapshot/stop lifecycle and check result validation. This explains why explicit reconnect needs account-specific invalidation. Full client coverage belongs to the protocol review. |
| `data/AccountStore.ets` credential replacement/rotation integration | The sole explicit `replaceOAuth` caller is the reconnect page. Initial account creation has no old session; ordinary `refreshOAuth` preserves its existing lease/envelope guards and does not trigger unnecessary watch replacement. NotificationStore, UnreadBadgeStore and encrypted storage internals are owned by the storage review. |

ArkTS paths in the table are relative to `harmony/entry/src/main/ets/` unless a longer prefix is shown. All seven notification-directory production files were reviewed. Related host tests and `port/swift-imap/InboxWatch.test.ets`, `InboxCheck.test.ets`, `InboxWatchTests.swift` and `InboxCheckTests.swift` were read. The native device test files were not executed in this review. Notification settings/prompt/banner views and ConnectedMail event consumption are covered by the UI review.

No further confirmed material defect was identified in this subsystem after these fixes. One malformed-server limitation remains unproven: an IMAP server returning successful but incomplete UID/FLAGS data may omit an arrival from that checkpoint. Requiring every requested sequence row would also reject legitimate concurrent EXPUNGE, and there is no existing safe completeness check that distinguishes the two without another protocol request. No speculative request or watermark change was added. The intended fifty-record bound also deliberately does not enumerate an arbitrarily large arrival backlog.

## Validation

Strict TypeScript compilation completed successfully:

```sh
.tools/runtime/node_modules/node/bin/node .tools/test/node_modules/typescript/bin/tsc harmony/entry/src/main/ets/mail/notifications/NotificationModel.ts harmony/entry/src/main/ets/mail/notifications/NotificationEngine.ts --strict --target ES2021 --module commonjs --rootDir harmony/entry/src/main/ets --outDir .tools/test-output
```

Each host test below was invoked directly as `.tools/runtime/node_modules/node/bin/node tests/<name>.test.cjs`. All 75 distinct tests passed with no failures (the final credential-adapter change reran the service and check-count suites):

| Test file | Passed |
| --- | ---: |
| `notifications.test.cjs` | 14 |
| `notification-service.test.cjs` | 22 |
| `notification-check-counts.test.cjs` | 5 |
| `mail-badge-service.test.cjs` | 6 |
| `notification-platform.test.cjs` | 13 |
| `notification-jmap.test.cjs` | 6 |
| `notification-banner.test.cjs` | 4 |
| `mail-unread-status.test.cjs` | 5 |

The coordinated native host command was:

```sh
scripts/test-imap-upstream --filter 'InboxWatchTests|InboxCheckTests|SMTPDeliveryCleanupTests'
```

It exited 0: fourteen tests in three suites passed (six watch, six Inbox check and two SMTP delivery-cleanup tests supplied by the protocol reviewer). This stages hash-verified pinned upstream sources with the explicit port patches and compiles them for the host; it is not HarmonyOS device evidence.

Exact commands, test output and exit codes are retained locally in ignored `.tools/review-notifications-host-2026-09.log`. Native preparation/build/test output is in `.tools/review-notifications-native-2026-09.log`. HarmonyOS compilation and any additional synthetic native runtime validation belong to the coordinating review; they are not claimed by this record.
