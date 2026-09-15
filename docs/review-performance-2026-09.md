# Performance and race review — September 2026

Objective: review the complete shipping HarmonyOS application and its active
Thunderbird Swift integration for performance issues, potential bugs and UI
races, with low-power operation and reduced code redundancy as requirements. Work starts from installed
0.1.14 and preserves the current uncommitted worktree.

## Completion requirements

- Review each shipping UI, storage, notification/lifecycle, protocol/operation,
  native adapter and packaging boundary; identify legacy/test-only exclusions.
- Trace concurrent ownership through navigation, account switching, mutation,
  draft saving, send completion, permission UI, settings and teardown.
- Bound repeated local work, timers, retries, server requests and queued writes;
  inspect scaling with larger cached inboxes, conversations, HTML and drafts.
- Consolidate repeated logic where it prevents inconsistent behavior or repeated
  work, keeping account ownership and protocol boundaries explicit.
- Fix confirmed defects without weakening offline retention, consent, account
  isolation, no-duplicate-send guarantees or the existing interface/split view.
- Verify behavior with deterministic synthetic races and work counters, host
  checks, production builds and prepared bounded native gates where appropriate.
- Record exact coverage, evidence and remaining limitations; do not infer actual
  device power consumption from an emulator or claim that tests prove no bugs.

## Coverage ledger

| Area | Owner | Current state |
| --- | --- | --- |
| Pages, compose/settings, conversation filtering, HTML presentation | root | Reviewed; findings, fixes and exclusions below |
| Encrypted data stores, cache, recipients, picture persistence | badge_storage | Reviewed; [storage coverage and evidence](review-storage-2026-09.md) |
| Notifications, foreground/background lifecycle, Swift IDLE/check | html_audit | Reviewed; [notification coverage and evidence](review-notifications-2026-09.md) |
| Protocol clients, native bridge, OAuth, SMTP/send, operations/attachments | badge_counts | Reviewed; [protocol coverage, evidence and follow-ups](review-protocol-2026-09.md) |
| Build/runtime entry points and production/test separation | root | Reviewed; production and isolated builds pass; boundaries below |
| Integrated regression/build/native validation and final coverage audit | root | Completed; final gates and installed artifact evidence below |

The previous goal turn made verified progress: 0.1.14 fixed refresh ownership,
row locking and a bounded cache retry regression, passed synthetic host/native
checks and was installed. That evidence is a baseline, not proof of this broader
review's completion. No production mail is accessed by this review.


## UI and presentation findings

The UI pass read all eight shipping pages (`ConnectedMail`, `ComposeMail`,
`Settings`, `HtmlMail`, both notification panels, `NewMailBanner`, and `Index`),
`AppLanguage`, conversation grouping, HTML document generation and the main
ability lifecycle. Native protocol/storage/notification boundaries are covered
by the three companion review records. The active app page list contains only
`Index`; synthetic fixtures remain in the separately generated test bundle.

| Finding | Change and deterministic evidence |
| --- | --- |
| Inbox conversation filtering repeatedly scanned the full folder for each row or nonmatching conversation. | One ID/Message-ID lookup per pass and one match calculation per thread. An actual-method fixture with 2,000 unthreaded rows previously performed 8,006,000 identity reads; the corrected method stays below 24,000. A 1,500-member nonmatching thread previously read 2,250,000 subjects, now exactly 1,500. Order, copied IDs, unread selection and Sent-header search remain covered. |
| Folder/index/flag overlays repeatedly copied or loaded full HTML bodies. | Metadata-only reads preserve body-availability ranking; the selected reader still retrieves its retained body through `email`. The cache rejects projected records as reader bodies. Pagination membership uses one Set, and row geometry is cleared when changing account/folder. |
| An older conversation index could replace a newer same-account index, losing a newly cached Sent member or restoring old flags. | Independent request ownership plus captured operation, account, view and navigation revisions guard every index completion. Two stalled-read regressions preserve the latest Sent member and flag state. |
| Repeated taps could duplicate reader work or stack multiple readers in tablet navigation. | An already pending/loaded current message is a no-op; selecting a different message remains immediate and reuses the reader destination. Existing stale header responses cannot replace that selection. |
| Native swipe actions remained disabled during a header refresh. | Read/star/Archive retain their permission and per-message pending checks while allowing a cached-row action during pull-to-refresh. Native swipe closure still precedes flag-keyed row replacement, with exactly-once dispatch. |
| Typing serialized and persisted a potentially large forwarded draft on every key. | Shared `DeferredSave` retains one latest edit, debounces for 400 ms with a maximum two-second debounce when no save is running, and flushes explicit/lifecycle boundaries. A slow active write can delay durability; one latest automatic edit waits behind it. A 500-edit large-draft burst across a slow save writes twice. Automatic typing does not grow a timer or storage-write chain. |
| A send started after a held draft flush could outlive an already-resolved teardown idle snapshot. | Teardown drains deferred saves before observing send/operation idle barriers. A held-save/held-preflight regression keeps storage open until the send finishes. |
| A slow discard remained editable and could recreate its deleted draft. | Discard disables editing before cancel/delete; late address/subject/body callbacks cannot schedule writes. The held-delete regression observes only DELETE. |
| Old composer initialization or account loading could publish after newer navigation. | Initialization/request guards prevent an old draft replacing the current draft; A→B→A account and teardown regressions reject superseded continuations. |
| Switching Settings account could hide a failed final signature/name save. | The final owned snapshot is saved before committing selection. Failed values remain visible and retryable; only the latest selection request wins. Edits made during a held save are also flushed. |
| Notification prompt refreshes repeated OS permission reads on ordinary Inbox events. | Only actual foreground transitions refresh the system setting. Each panel ignores 2,000 unchanged synthetic events and checks once on resume. |
| Deep HTML quote parsing repeatedly searched its open-tag stack. | Tag-position indexes match and unwind each open tag at most once. A 12,000-level malformed/deep quote regression preserves folding without the repeated scan. |
| Every picture progress update rescanned unchanged authored HTML. | Remote-reference presence is memoized by the exact HTML string. 250 repeated checks scan once; changed HTML scans again. Existing remote consent, retry, offline bytes, forced dark adaptation and quote behavior remain intact. |

The first large native Inbox gate caught an additional gesture/state issue:
while the synthetic page remained held, the short upward gesture dismissed pull
feedback and allowed the search header to reveal. The following downward check
failed. Native `refreshing` feedback was being reused as request ownership.
`mailboxRefreshActive` now tracks the owned request independently, so gesture
feedback cannot disable row actions or resize search while the request is pending.
The retest uses actual list displacement away from the pull edge as well as
held-request action/reader assertions, rather than treating pull-header movement
as proof of content scrolling. The failed run and its synthetic screenshots are
retained under the private emulator evidence directory.

Account create/remove completions also now retain their originating generation:
an older write cannot clear a newer spinner or replace its account list. Removal
keeps its original notification cleanup, selects a remaining account, or clears
the final live reader/client. A failed post-delete catalog read falls back to the
known remaining accounts so a committed deletion cannot leave its client live.

## Redundancy reduced

`DeferredSave` is the shared composer/settings editing queue. The typed
`shallowCopyEmail` helper is shared by cache reconciliation and optimistic
operations, replacing repeated deep copies while preserving immutable body
strings. AccountStore uses one Asset secret-query implementation across its
three callers. Local Sent reconciliation builds one shared lazy identity index
per saved page. Notification backoff uses the existing due-time helper, avoiding
different retry rules in the watch path. No protocol implementation or account
ownership layer is replaced by a generic abstraction.

## Build and runtime review boundaries

Reviewed the shipping main ability, non-exported WorkScheduler extension,
module/page declarations, compile/target settings, native linker staging and
source-parity verifier. The pinned Swift modules and explicit port patches are
retained; the generated diagnostic bridge is absent from production HAPs. No new
permission, private push server, release identity or OAuth registration is added.
The development build continues to target API 22 while compiling with SDK 26.

List children under the existing ForEach are created as they are laid out;
changing to LazyForEach solely on an assumption that all full rows are built at
launch would be unjustified. It remains a possible wrapper/key/memory improvement
if native profiling demonstrates that cost, with datasource, swipe and scroll
anchor regressions required. See the [OpenHarmony list lifecycle documentation](https://raw.githubusercontent.com/openharmony/docs/master/en/application-dev/ui/arkts-layout-development-create-list.md).

This review covers shipping application code and its active Swift adaptations,
not every line of vendored SwiftNIO/Foundation, dormant upstream UI or platform
internals. Native power/temperature, exact real-provider behavior and the
unidentified image resource from the user's screenshot are not measured.
The protocol report explicitly retains the known IMAP timeout/authentication
classification bug and connection setup costs as follow-ups; the review does not
claim that all possible bugs or performance limits are eliminated.

## Integration gates

Completed against development 0.1.15 (100015):

| Gate | Result |
| --- | --- |
| Full host regression | 411 JavaScript tests across 44 files and nine Python tests passed, no failures or skips. |
| Swift host integration | 14 tests across InboxWatch, InboxCheck and SMTPDeliveryCleanup passed. Native cores rebuilt for x86_64 and ARM. |
| Native encrypted storage | Passed, 9.529 s: actual SQL header projection, original offline body retention, pending-write close/reopen ordering and stale-handle rejection; zero mail calls. |
| Large native phone Inbox | Passed, 74.887 s: 2,000 cached headers, actual upward/downward drags, read/star acknowledgements and cached reader before the held page resolves; one client, one page, two flag operations, zero body/other requests. |
| Large native tablet Inbox | Passed, 75.218 s: same stalled-response gate; reader retains the split view. |
| Native tablet presentation | Passed, 38.723 s: two held refreshes, no extra app spinner, stable header geometry, search hidden away from the top and settled at 56 vp at the top; cached reader and split view survive late results. |
| Native picture retry | Passed, 16.356 s: actual NetworkKit/ArkWeb download, replacement and coalesced retry; two HTTP 503 failures retain cached bytes, timestamp, consent and visible pixels. Four loopback requests only. |
| Build and source parity | Production x86, signed ARM, isolated main and isolated test HAPs built. All 52 shipping page/data/mail/core/model files match isolated staging; all shipping main sources and native libraries match signed ARM staging. Renderer tracing is disabled. |
| Installation | In-place 0.1.15 upgrades on Pura X and MatePad; models, package version and signed HAP hash verified. No data clear, production launch, mailbox read or send. |

Every prepared emulator session stopped on completion and native-process absence
was separately verified. Selected synthetic phone, tablet and picture screenshots
were visually inspected. The initial failed gesture gate is retained privately;
the final phone and tablet gates exercise the corrected request state. The
storage gate preceded the final UI-only fix; its storage source stayed unchanged.
Earlier 0.1.14 results are retained separately and are not counted as new tests.

The independent final coverage check clarified the debounce bound, the
one-shot-connection exceptions and intermediate test totals. Exact hashes and
test scope are recorded in [0.1.15 validation](../port/mail-corpus/release-0.1.15-validation.json).
The [release note](release-0.1.15.md) summarizes the user-visible changes. The
known follow-ups and exclusions above remain part of the completed review.
