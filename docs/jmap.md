# JMAP backend

The initial connected-mail backend reimplemented upstream operations in ArkTS.
Account discovery, mailbox loading, message lists and plain-text reading now call the original Swift JMAP client
through [the native account bridge](native-jmap.md). `JmapClient.ts` now routes every current connected protocol operation, including draft creation, to the required Swift core. The older ArkTS protocol implementation and Remote Communication Kit transport exist only under `src/ohosTest/ets/support`; they are excluded from the shipping HAP. Read/unread, stars and archive/undo now run through Swift workflows.

The implementation follows [JMAP Core](https://www.rfc-editor.org/rfc/rfc8620.html) and [JMAP Mail](https://www.rfc-editor.org/rfc/rfc8621.html). It uses the session's account and capability data, correlates method responses with requests, and fetches summaries separately from text bodies. Server mailbox roles determine their meaning; localized names do not.

## Current behavior

- Callers supply an HTTPS session URL and a credential provider. Credentials are requested for each operation and are not saved or logged by the client. Basic and bearer authorization headers are supported; the account layer obtains stored tokens through Asset Store.
- Session discovery is shared between concurrent callers. Returned session values cannot mutate the client's internal account list or API endpoint. The primary account is retained separately from shared accounts; callers explicitly select the account used for each operation.
- Discovery follows at most three redirects within the same HTTPS origin. API POST redirects are rejected. Cross-origin API URLs currently return `untrustedApiOrigin`; adding explicit endpoint trust to account setup is still required for those providers.
- Summary pages contain at most 50 messages, also bounded by the server's `maxObjectsInGet`. The cursor advances over queried IDs, including messages deleted between query and fetch. A changed query state raises `queryChanged`, so callers must restart pagination instead of appending an inconsistent page. A short page without a total is not assumed to be the end.
- Server email IDs, RFC message IDs, thread IDs, multiple mailbox memberships, keywords, and Reply-To addresses remain distinct. They are not converted into the preview's single-folder snapshot.
- Text bodies are fetched on demand with a 256 KiB limit per part. Truncation and encoding status remain explicit. An HTML-only message has no plain-text body; its preview is never returned as a full body. Remote images and attachments are not fetched.
- `setKeyword` uses an `Email/set` patch for one `$seen` or `$flagged` key, with `true` to add and `null` to remove it. It refuses read-only accounts and validates the per-message acknowledgement, including `notUpdated` errors. Unrelated keywords and mailbox memberships are never replaced. Writes are not retried automatically. The UI checks mailbox rights, refetches the message/counts after changes, and requires Refresh after an unconfirmed outcome.
- The native transport rejects cross-origin requests and cancels responses larger than 4 MiB while receiving them. The Swift account/reader bridge uses FoundationNetworking with platform trust policy and 30-second request/resource timeouts. Request sessions close on success and failure, and errors omit server descriptions, credentials and message contents.

Archive resolves Inbox/Archive by server role, refetches the message and uses a membership patch with `ifInState`. Undo checks the current memberships, preserves unrelated keyword changes, and patches only the affected Inbox/Archive keys. The same state precondition prevents races after the check. Missing or ambiguous roles, denied permissions, later mailbox changes and uncertain responses are surfaced without write replay.

## Verified

The production account bridge passes five HAP tests against a local TLS fixture,
alongside six reader-bridge tests, six message-change tests, five draft tests, four direct original-client tests and six networking tests. The older
tests below establish prototype behavior; their separate test-only client never substitutes for the production Swift bridge. No live provider is configured.

`./scripts/test` runs six preview-model checks, 37 historical JMAP protocol tests, four production facade checks and five cache-format tests. Coverage includes pagination with deleted messages, fractional timestamps, stale query state, malformed responses, response correlation, primary/shared accounts, redirect policy, authentication failures, body completeness, retry after failed discovery, targeted keyword patches, mailbox permissions, per-message write errors, contradictory acknowledgements and no automatic write replay.

Build with the emulator stopped, then run the prepared historical tests:

```sh
./scripts/test-device build
./scripts/test-device device
```

The build command prepares the app and `entry_test` HAP. The device command starts the emulator, installs them, creates a temporary self-signed certificate, starts a loopback-only synthetic HTTP/TLS fixture, forwards emulator ports 9555/9556, and runs 15 native tests. Seven cover discovery/list/query/read I/O through the actual platform adapter, UTF-8 chunk handling, response-size cancellation, HTTP authentication classification, no automatic redirect following, rejection of the untrusted TLS certificate, and HTTPS enforcement. Two more create/read a synthetic draft and verify no replay after its acknowledgement is lost. Six further tests cover account/credential storage, cache persistence and migration, and the native setup-to-reader UI flow including offline fallback and reconnection.

The test HAP alone maps a virtual fixture origin to a loopback HTTP server. It uses a fixed synthetic token. The production client has no insecure-mode option. Fixture-side counters independently confirm the method sequence, zero redirect follow-ups, and a rejected TLS handshake. Forwarding, server processes, and generated key material are cleaned up when the script exits; the wrapper stops the emulator even on failure. Test results stay in ignored `.tools/jmap-device-test.log` and `.tools/jmap-fixture-stats.json`.

The device tests run on HarmonyOS 6.0.2 API 22. These are local fixture tests, not validation against a live mail provider. UI-test mode is enabled temporarily and cleanup restores an observed enabled setting or requests disabled mode when it cannot be read; the test reader is captured before the runner closes its window.

## Next integration work

The UI now offers [connected account setup, reading and keyword actions](accounts.md), with Asset Store tokens and encrypted RDB account metadata. Fetched lists and opened bodies use an [encrypted offline cache](cache.md). Plain-text [draft creation](drafts.md) is implemented and tested in the backend. Its connected composer and durable upload/reconciliation workflow remain unfinished, along with incremental synchronization, provider discovery/OAuth, live-provider verification, general folder moves and submission. `Mailbox/get` currently reports `tooManyObjects` for accounts exceeding the server's all-mailboxes limit; mailbox query pagination is still needed. Only synthetic fixture messages have been changed during testing; no email has been sent.
