# Minute-level background mail checks

Checked 2026-09-14 after release 0.1.7. The user needs checks every few minutes
and rejects a privately operated relay dependency. The installed two-hour
fallback does not satisfy that requested frequency.

Huawei's current WorkScheduler API requires a repeat interval of at least two
hours. The OS also decides actual dispatch time. Changing the UI or registering
five-minute recurring jobs would not provide supported minute-level execution.
[Huawei WorkScheduler API, updated 2026-07-09](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/js-apis-resourceschedule-workscheduler)

Continuous background execution is a separate capability. OpenHarmony documents
TASK_KEEPING on non-2-in-1 devices from API 21 with the restricted
KEEP_BACKGROUND_RUNNING_SYSTEM permission. The documented purpose is computing;
neither the current docs nor the bundled SDK through API 26 provides an ordinary
mail-listening mode. Transfer, audio, casting and media-export modes must match
the operation being performed; they are not general-purpose idle mail listeners.
[Continuous-task modes and restrictions](https://github.com/openharmony/docs/blob/master/en/application-dev/task-management/continuous-task.md)

Huawei documents an ACL application process through AGC/DevEco, including temporary
debug profiles and approval for release. The signing guide explicitly lists
KEEP_BACKGROUND_RUNNING_SYSTEM among supported restricted permissions. This is a
possible route to investigate, not evidence that mail listening will be approved.
A temporary debug entitlement would not establish release eligibility.
[Huawei signing and restricted-permission approval, updated 2026-09-03](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)

No permission application was submitted and no device configuration changed.
Production uses foreground IMAP IDLE and OS-deferred background work.
The notification and unread-indicator updates do not change these execution limits.
Reliable minute-level background mail remains unresolved pending a suitable,
approved execution capability. Such a capability would allow direct IMAP
monitoring and would not inherently require a private relay.

## Why ten staggered registrations do not promise twelve-minute checks

The ten-job allowance is a registration limit. The current official OpenHarmony
[Constraints section](https://github.com/openharmony/docs/blob/master/en/application-dev/task-management/work-scheduler.md#constraints)
also places execution-frequency restrictions on the application activity group:
active applications have a minimum two-hour interval; less active groups use
four, twenty-four or forty-eight hours. Dispatch is chosen by the system.

The upstream implementation groups tasks by UID and updates shared UID timing
when a task starts successfully. See
[UID queues](https://github.com/openharmony/resourceschedule_work_scheduler/blob/master/services/native/src/work_policy_manager.cpp#L113-L129)
and [successful start](https://github.com/openharmony/resourceschedule_work_scheduler/blob/master/services/native/src/work_policy_manager.cpp#L470-L502).
This does not provide a supported twelve-minute schedule by rotating ten IDs.
We have not measured an exact batching algorithm on the commercial firmware,
and did not change production scheduling to claim this guarantee.
