# 0.1.17 — keep saved pictures and retry only missing content

The reader previously forced every image to download again when the user tapped
Refresh pictures. If that replacement failed, it displayed a download-failure
warning even while serving the good saved bytes. This reproduced behavior can
explain a warning on a correctly cached picture; the private newsletter itself
was not inspected.

## Pictures

The reader now always asks for cached pictures first. Retry pictures reloads the
local document and requests only missing or invalid pictures. Concurrent retries
join the same missing-image download. Saved bytes and their retention timestamps
are unchanged. Once picture loads finish successfully, the retry control and its
row disappear. Returning to the message uses the saved pictures without HTTP.
Normal seven-day cache retention remains in effect.

Failure text counts only pictures with no usable saved copy, or pictures that
could be displayed but could not be saved. A failed replacement with a usable
saved image does not count as a missing image. A cache-write failure still returns
the downloaded image for display and keeps retry available. A failed ArkWeb
navigation cannot hide the only retry control; previous failures remain until
that resource recovers. No provider URLs or raw responses appear in status text.

A combined renderer/SQLite regression starts with three good pictures and two
connection failures. Each retry makes exactly two requests, preserves the three
original records, and clears errors when the missing pictures are saved. Once all
five are saved, another retry and renderer/cache recreation offline make zero HTTP
requests and preserve all bytes and timestamps.

## Other review fixes

- Startup cache validation keeps the original serialized payload when retention
  and preview fields already match. In the synthetic 24-body fixture this avoids
  24 serializations totaling 4,934,442 characters; validation and expiry behavior
  remain covered.
- A pending notification tap no longer polls every 300 ms while the app is busy
  or hidden. Existing foreground and completion events resume it. Navigation
  commits before optional notification dismissal, so a slow preference read
  cannot override a later account selection or lose a tap during composition.
- The original Swift IMAP client now distinguishes explicit authentication
  rejection from a disconnected, timed-out or malformed exchange and a failed
  post-login CAPABILITY command. Only explicit rejection asks for credentials
  again. This adds no connections or retries and does not enable Google browser
  sign-in. A missing advertised authentication capability remains a safe generic
  network error; it sends no token and does not fall back to a password.

## Validation

All 439 JavaScript tests across 45 files and nine Python tests passed. All 79
Swift host tests passed, including 19 actual-client loopback TLS authentication
scenarios. The final 25 renderer tests also passed after the navigation-race fix.

All four HAP builds passed (isolated main/test, production x86 and signed ARM).
The native x86 and ARM Swift cores were rebuilt; 52 shipping source files and
both localizations match the isolated fixture, with diagnostic tracing disabled.
Nine native tests passed in one bounded emulator run:

- Seven IMAP/SMTP OAuth tests, including rejected credentials and unsupported
  authentication without token transmission or password fallback.
- One encrypted-cache gate (9.296 s) preserving 65-header batch order, dirty flags,
  original offline body and close/reopen behavior.
- One picture gate (22.106 s): one good download plus two missing images,
  repeated held retries, recovery, and renderer recreation with every HTTP
  resource unavailable. Per-URL requests were exactly 1/3/3; recreation made
  zero requests. Saved bytes/timestamps remained identical; retry and warnings
  disappeared. Synthetic partial and reopened screenshots were visually checked.

The emulator stopped and native-process absence was separately verified. Version
0.1.17 was installed in place on Pura X and MatePad and bundle metadata verified,
without clearing data or launching production. Artifact hashes and detailed
results are in [the validation record](../port/mail-corpus/release-0.1.17-validation.json).
AppGallery was not rebuilt.

No production mailbox was opened, no real mail was collected or sent, and no
physical screen or thermal measurement was taken. Tablet split navigation is
preserved. Optional IMAP mailbox-count/logout delays, connection reuse and the
MIME/CID edge cases from the broader review remain separate follow-ups.
