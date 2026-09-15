# Storage review — September 2026

Reviewed against the installed development baseline 0.1.14 on 2026-09-14.
This review used source inspection and synthetic host fixtures. No production
mail, device data, remote providers, emulator, installation or packaging was used
by the storage reviewer. The changes below are subsequent source changes, not a
claim that a new release is installed.

## Reviewed files

All paths below are under `harmony/entry/src/main/ets/data/`.

| File | Review coverage and result |
| --- | --- |
| `AccountStore.ets` | Open/close ownership, serialized work, background-only opens, OAuth refresh/leases, account removal, Asset writes, draft/settings reads and recipient backfill. Fixed close/reopen and stale-handle races, tracked metadata reads through teardown, guarded late SMTP settings writes, and selected header-only recipient reads. |
| `MailCache.ets` | Startup retention, folder and conversation reads, Sent reconciliation, mutations and state revision guards. Added body-free projection/fallback, a shared lazy local Sent index, bounded startup batches and a dirty-record index; fixed expired bodies in folder reads and quadratic view-membership tests. |
| `MailCacheModel.ts` | Cache validation, immutable copies, body/summary retention and decoder compatibility. Added explicit summary-only safety and removed redundant full-body JSON round trips. |
| `NotificationStore.ets` | Toggle/configuration revisions, silent baseline, durable outbox acknowledgement and cross-process lease acquisition. Existing post-commit lease ownership check retained; no storage API change. |
| `UnreadBadgeStore.ets` | Exact enabled-account totals, unknown counts, pending projections, dirty guards and pooled-reader revision rules. Existing semantics retained; dirty checks benefit from the new partial index. |
| `RecipientStore.ets` | Account isolation, encrypted history updates, limit enforcement, queued inputs. Replaced whole-history rewrites with changed-row writes and snapshotted queued additions. |
| `RecipientHistory.ts` | Case-insensitive keys, names from confirmed Sent mail, bounded history, suggestions and active-token replacement. No correctness change required. |
| `CompositionSettings.ts` | Sender normalization, signature length/control bounds and one-time draft application. Existing behavior retained; UI write debouncing is reviewed separately. |
| `LocalMailbox.ets` | Preview-only immutable preference snapshots and write ordering. No production-account path or change. |
| `OAuthSecretBox.ets` | Per-account AAD, envelope bounds, key retention/rotation, temporary-buffer cleanup and Asset removal. Existing implementation retained. |
| `PictureCache.ets` | Consent, request coalescing, queue slots, failure fallbacks, retention and storage budget. Fixed budget accounting with pooled readers; existing download/status and offline-copy guarantees retained. |
| `PictureData.ts` | Generic/wrong raster MIME recognition, recognized aliases, textual rejection and cached-byte validation. Existing 0.1.14 alias fix retained. |

## Confirmed fixes

1. **A reopen could return a database that an older close would subsequently
   shut down.** `close()` now exposes one shared flight, and both open methods
   wait for it. The final close is a serialized barrier after picture work,
   token refreshes, notification changes and queued writes. Child-service queues
   capture the database and its generation; retained old handles fail before
   native access, including when a wrapper object is reused. Account listing,
   last-visited selection, composition and draft reads now participate in the
   same queue rather than racing close after merely awaiting an old queue tail.

2. **Header-only tasks carried every downloaded body into ArkTS.**
   `cachedMessages(accountId, false)` and
   `view(accountId, mailboxId, includeDirty, false)` use a once-per-instance
   SQLite JSON capability probe. Supported databases project out text/HTML bodies
   and attachment metadata before returning payload strings. Unsupported builds
   use the existing read and strip each decoded record without retaining its
   bodies in the result. Projection preserves body download/decoder metadata,
   marks `summaryOnly`, and supplies the local `cachedBodyAvailable` hint for
   conversation ranking. Reader readiness rejects projections. Full-body saves
   reject projected inputs; summary saves discard the hint and preserve the
   existing body and retention timestamp. Default reads and `email()` still
   return actual retained bodies.

3. **Folder reads could return expired body bytes before the next foreground
   initialization.** `view()` now applies the same body-retention rule as other
   cache reads. Headers and folder state survive while expired body/attachment
   fields are removed from the returned value.

4. **Startup pruning duplicated the complete retained mailbox in memory.**
   The pass now processes at most eight rows at a time in rowid order. Deletions
   cannot shift an OFFSET and skip later records. It still validates all records
   and retains the existing seven-day policy. A partial covering index over
   dirty email records avoids scanning all account mail for badge dirty guards.

5. **Repeated header reconciliation performed quadratic membership work and
   redundant full-body serialization.** Fetched row IDs and MIME Message-IDs use
   Sets. `cacheEmail()` uses a shallow working copy before its final validated
   deep copy; flag/move acknowledgement comparisons retain the old immutable
   arrays instead of serializing a body just to compare flags or membership.
   Local Sent-body recovery now builds one lazy Message-ID-to-local-ID index
   per saved page using the header projection. Only a matching local copy
   triggers a full-body read; unrelated headers no longer repeatedly decode
   every local Sent body.

6. **One learned recipient rewrote up to 500 encrypted rows.** History changes
   now upsert only changed records and delete only evicted keys. A full history
   needs one statement to update an existing recipient, two to add a recipient
   and evict the oldest, and zero data writes for unchanged/older backfill.
   Caller-owned additions are copied before entering the queue. Reading and
   applying a merge remain within one transaction.

7. **A settings save queued after account deletion could recreate an orphan
   SMTP Asset.** The queued write now checks that its account is still ready
   before updating or creating credentials. Provider endpoint/login checks and
   background credential restrictions are unchanged.

8. **The picture budget read its own uncommitted writes.** A native pooled
   reader may omit the just-inserted picture or see its previous size. Budget
   calculation now reads committed, unexpired survivors before writing, excludes
   the replaced key, and adds the incoming byte length explicitly. The original
   transaction, oldest-first eviction, account isolation and failed-refresh
   retention are preserved.

## Narrow redundancy cleanup

Incoming authorization, optional background access and SMTP settings now share
one private Asset-secret query helper. Each caller retains its existing handling
of missing credentials, error classification and `finally` buffer clearing.
The flag/membership snapshots use the shared typed `shallowCopyEmail` utility
also used by pending mail operations; arrays are replaced by their owning
mutations, and bodies are not serialized to make the snapshot. Explicit callback
typing keeps the recipient-input snapshot compatible with ArkTS.

## Verification

Focused tests passed using the bundled Node runtime and synthetic SQLite/HTTP
adapters:

| Test file | Passed | Relevant evidence |
| --- | ---: | --- |
| `tests/background-credentials.test.cjs` | 18 | Paused picture work plus a queued write hold close; reopen waits; repeated close joins; stale cache generation cannot execute; metadata reads finish before close. Existing separate-reader OAuth/notification lease and revocation cases pass. |
| `tests/sent-cache.test.cjs` | 12 | SQL projection returns strings under 5 KB for a roughly 1 MB synthetic body; fallback probes once; expired/fresh ranking, original body retention, projection write rejection, bounded pruning without skipped deletions, dirty-index query plan and prior Sent reconciliation cases pass. A page with 40 unmatched headers and one matching header performs one local Sent index scan and one large-body read. |
| `tests/picture-cache.test.cjs` | 32 | Separate-reader WAL budget regression, coalescing/queued refresh, bounded concurrency, failed refresh retention, MIME handling and account isolation pass. Virtual blob lengths avoid allocating hundreds of MiB for the budget fixture. |
| `tests/recipient-history.test.cjs` | 10 | Changed-row write counts, queued-input mutation protection, account isolation, 500-record limit, confirmed-delivery learning and header-only backfill calls pass. |
| `tests/oauth-smtp-settings.test.cjs` | 6 | A password-settings save queued behind removal performs no Asset write; endpoint/login and background restrictions pass. |
| `tests/unread-badge-store.test.cjs` | 9 | Exact counts, enabled-account filtering, unknown counts, local mutation/overlay and pooled-reader guards pass. |
| `tests/composition-settings.test.cjs` | 5 | Sender/signature normalization, account-local persistence and one-time draft application pass. |

`port/swift-imap/StorageReview.test.ets` and `StorageReviewRunner.ets` prepare a
bounded, socket-free native gate in the isolated test app. It asserts that
`hasSqlSummaryProjection()` is true on the target RDB, projected reads preserve
the actual offline body, a projected summary write cannot replace that body,
pending composition writes survive concurrent close/open, and an obsolete cache
handle is rejected. It uses only synthetic data and prints success after cleanup.
Native execution and the complete integrated suite belong to the parent review;
their results must be recorded separately before release.

## Remaining performance limits

- JSON projection reduces ArkTS transfers and retained memory; it is not a
  separately persisted header index. Cold scans still read and parse the stored
  JSON in SQLite. The fallback also parses each original record in ArkTS.
- Startup validation remains linear in retained records, although memory is
  bounded by the batch rather than the entire mailbox.
- Picture requests retain their existing four-request limit and SDK timeouts.
  Already authorized queued downloads can outlive the reader so completed bytes
  remain available offline. This review does not establish the cause of physical
  device warmth or claim a measured battery improvement.
