# Offline mail cache

Connected accounts now save fetched mailbox metadata, loaded message lists and opened message bodies in the same encrypted RDB database as their account metadata. The cache is separated by local account ID, even if two accounts use the same server-side message IDs. Tokens remain in Asset Store.

When the server cannot be reached, Accounts can open saved mailbox metadata, a previously loaded mailbox list, and a previously opened message body. The interface labels the saved copy with its timestamp. A message whose body was never downloaded is identified explicitly. Offline pages do not offer network pagination, and server-changing actions remain disabled until fresh data is loaded. Refresh reconnects to the server.

This is a cache of fetched data, not complete mailbox synchronization. Unopened message bodies, unloaded pages, attachments and HTML content are not downloaded for offline use. Background synchronization, storage limits/eviction, an offline write queue and cache-management settings remain pending.

## Consistency and recovery

Database schema 2 adds an account-scoped `mail_cache` table without replacing schema 1 account records or credentials. Cache envelopes have their own version and validated fields; corrupt cache data raises a readable error instead of returning unchecked mail. Message records and mailbox-view ID lists are separate. Saving a view and its message summaries is transactional.

A fresh summary updates mutable metadata while retaining a previously downloaded body and its timestamp. JMAP message bodies are immutable; flags and mailbox memberships are separate mutable properties. Cached views resolve their IDs through the current message records and filter memberships, so an archived message is not returned in a saved Inbox after reconciliation.

Before a mutation, the message's cached record is marked dirty. Dirty records are excluded from offline lists and readers until a fresh server read reconciles them. Mutation writes are not replayed automatically. Archive and undo also refresh the affected body record and current mailbox list.

Disconnect first marks the account deleting, then removes its credential, cached mail and metadata. Reads only expose ready accounts. Interrupted removal is resumed on the next open, and late cache writes cannot recreate data for a removed account.

## Validation

Host tests cover cache format validation, identifiers, old message dates, immutable copies, lazy body state, HTML-only body state, summary/body merging and account-independent record semantics. Native storage tests cover encrypted persistence across reopen, account isolation, dirty-record filtering, membership changes, account removal and migration from schema 1. The native UI test restarts its ability while the fixture is unavailable, verifies saved folders/list/body and disabled mutation controls, then verifies Refresh restores online controls. Whole-process termination and OS restart are not covered by this test; see the current results in [validation](validation.md).
