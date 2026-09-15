# 0.1.12 — inbox movement, summaries and picture retries

Keep the existing inbox styling and tablet split navigation. Native Refresh
provides the pull animation and its single loading indicator. Initial loading
belongs inside an empty list; short-lived action progress no longer inserts a
second indicator or moves the list header. Reveal or hide search after a drag
settles, with a short height transition. Keep nonempty search available.

Native row identity depends on displayed text and action state rather than the
whole message object. Downloading a large body or updating unrelated metadata
must not recreate the row and interrupt its swipe state. Read/star changes still
wait for the native action panel to close before applying the displayed update.

Inbox previews retain server-provided and previously cached text. Servers without
a usable preview get a small optional sample of an inline text MIME part;
downloaded summaries are reused on subsequent refreshes. Attachment and complete
message bodies are not downloaded solely for an inbox summary.
Blank or failed body decoding also retains an existing summary for that message.

Refresh pictures remains usable while previous requests are pending. Render
refreshes wait for committed frames without waiting for an idle document, and a
discarded native Web response cannot leave the loading counter stuck. Invalid
common image payloads cannot replace a good cached image. Successful fresh bytes
can display even if saving them fails; a failed download preserves the old copy.
Native validation reproduced a reload that never reached document interception.
A button-triggered load can carry a user-gesture flag; the old navigation guard
blocked it even when it targeted the app's own document. The guard now permits
the exact current local URL and still rejects foreign or superseded URLs.
Refresh explicitly loads a new local document URL, and intercepted responses use `Cache-Control: no-store`,
while remote URLs, encrypted picture-cache keys and per-message consent stay
the same. No cache-busting parameters are sent to picture servers.

## Validation

All 311 JavaScript tests, nine release-package Python tests and 14 focused Swift
tests passed. Native emulator gates passed for phone inbox presentation
(26.911 seconds), repeated read/star swipe actions (31.185 seconds), tablet inbox
presentation and split navigation (29.724 seconds), seven IMAP preview sessions
(2.061 seconds), and picture retries (14.705 seconds).

The inbox gate held one synthetic refresh with 80 cached rows and confirmed no
extra app spinner, stable row/header geometry, and settled search transitions.
The preview gate covered server PREVIEW, cache hints, plain/HTML samples, UTF-8
boundaries, missing/duplicate/oversized replies and a stalled server. Its seven
sessions made five bounded sample FETCH commands and no full-body, attachment or
Seen-mutation requests. The picture gate used the byte-identical shipping
renderer, two controlled HTTP 503 responses, persistent cache checks and matching
image pixels before and after retries. Diagnostic instrumentation was off.

Earlier preview fixture failures were corrected by advertising capabilities in
the client's supported untagged form and accepting digits in allowlisted test
scenario names. The picture fixture needed a cleartext allowance only for its
127.0.0.1 HTTP server; that allowance exists only in the isolated test package.
Production network settings were not broadened. Prepared emulator sessions
stopped automatically and native-process absence was checked separately.

Production x86, signed ARM and both isolated test HAPs built with CLI
26.0.0.821, Hvigor 6.26.4 and compile SDK 26.0.0.105. Target/minimum and the
Swift native sysroot remain API 22. Development bundle identity remains
`org.thunderbird.harmony.dev`; the separate AppGallery package was not rebuilt.

Development version 0.1.12 (100012) is installed and metadata/hash-verified on
Pura X and MatePad. Both received the same signed HAP through in-place upgrades,
preserving saved accounts. Production was left closed; no real mail was read or
sent. See [machine-readable evidence](../port/mail-corpus/release-0.1.12-validation.json).

Summaries may remain blank when the bounded sample contains no readable text.
Image validation checks common file signatures rather than fully decoding every
format. Remote servers can still fail; an existing valid cached image survives.
