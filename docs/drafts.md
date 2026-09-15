# Connected draft creation

`JmapClient.createDraft(accountId, draft)` now calls the Swift core to create a plain-text draft in the selected account's server-designated Drafts mailbox. The explicit `draft-creation.patch` uses Thunderbird's shared SET request encoder and response models. This is a backend capability; the connected composer, encrypted local draft lifecycle and server draft editing are still pending. The sample composer continues to save local sample drafts only.

The request follows [JMAP Mail, Email/set](https://www.rfc-editor.org/rfc/rfc8621.html#section-4.6). It includes the draft and seen keywords, one plain-text body part, separate To/Cc/Bcc/Reply-To fields, and optional reply message IDs/references. It preserves Unicode and incomplete draft addresses. Header controls and malformed input are rejected, and body content is limited to 256 KiB of UTF-8. The client also checks the encoded JSON request against the advertised core `maxSizeRequest` and its local 4 MiB ceiling before POSTing. A server that omits the limit uses the local ceiling.

The input is copied before asynchronous discovery or mailbox lookup. The client refuses unknown/read-only accounts, missing or ambiguous Drafts roles, and a mailbox without permission to add messages. Folder names do not determine the destination. Successful creation returns the acknowledged message/blob/thread IDs, size, state and destination mailbox; it does not invoke EmailSubmission or send mail.

## Save outcomes

Validation, discovery and mailbox-lookup failures occur before creation. A well-formed per-object rejection throws `JmapDraftError` with `mayHaveCreated: false` and a sanitized error code. Once creation is attempted, missing, malformed, contradictory or lost acknowledgements are reported with `mayHaveCreated: true`. This is deliberately conservative: an ambiguous HTTP or method error does not prove that no draft exists.

Creation is never retried automatically. A JMAP creation ID correlates one request and cannot be used as a persistent idempotency key. A future composer must persist its pending upload before sending, retain local text on every failure and reconcile uncertain outcomes before allowing a repeat upload. The protocol method alone does not provide that durable workflow or deduplicate separate calls.

JMAP message content is immutable. Updating a server draft needs a replacement message, preservation of the old draft until the new copy is acknowledged, conflict checks and recovery of partial outcomes. None of those are currently exposed as a draft-edit operation.

## Verification

Five production-bridge HAP tests now exercise Swift draft creation: a 150,000-byte
Unicode body, separate recipient fields and unfinished addresses, input
snapshotting, empty drafts, account/folder rights, byte limits, definite
rejections and uncertain outcomes. The local fixture verifies one creation per
attempt, the exact saved input and zero submission calls. Reading the saved draft
uses the original Swift Email decoder. All fixture mail stays local and disappears
when the fixture exits.

The earlier eight host tests and two Remote Communication Kit HAP tests cover
the prototype implementation. They remain historical/prototype regression
coverage, separate from the Swift evidence above.

See [validation](validation.md) for the complete suite. Native compose input, durable connected drafts, replacement/reconciliation, live-provider interoperability, identities and sending remain unfinished.
