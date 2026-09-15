# 0.1.16 — shorter Inbox refresh and bounded hidden-picture work

The user reported slower Inbox refresh after 0.1.15, plus heat after backgrounding,
locking the screen or dismissing the app. This update corrects reproduced extra
work and refresh dependencies. It does not claim a measured physical temperature
improvement or identify every contributor to the reported delay.

## Refresh changes

- Cached folder reads now fetch at most 64 records per database query instead of
  issuing one query per message. A synthetic 71-entry view requires three queries
  instead of 72, while preserving saved order, account isolation, dirty flags,
  pagination and body retention. SQL projection still keeps body strings out of
  the Inbox's ArkTS records.
- Visible refresh completes after Inbox headers and their cache write. It no
  longer awaits an account-wide conversation scan and another Sent-folder server
  session. Those updates continue separately while the app remains eligible.
- Repeated pulls allow one companion request in flight and retain only the latest
  superseding intent. An obsolete response cannot replace a newer folder view;
  one successor may run if that latest view is still current and foreground.
- Backgrounding during a cache read prevents a new automatic/manual page request.
  Optional Sent work also checks foreground and composition before requesting.
  Already downloaded current headers remain cached. Invisible conversation-index
  work pauses and resumes once from cache without requiring a new arrival.

## Background-picture changes

Previously, leaving a message with four active picture requests and three waiting
requests still started all seven downloads. The cache now checks foreground and
account/message ownership before admitting a request and after awaited consent.
The same fixture starts only the original four. A quick background/foreground
transition cannot revive the old queued work, and closing one message does not
cancel another visible message's requests.

The main ability applies the picture gate on foreground, background, window
destruction and destruction. HtmlMail cancels its previous picture identity on
change/disappearance, suppresses hidden document callbacks and resumes cache-first.
Canceled queued work is retryable and does not create a failure notice. Existing
good bytes, consent and retention timestamps remain intact. Up to four already
active downloads may finish and save their bytes; this is not immediate network
termination.

The notification lifecycle review found no demonstrated perpetual IDLE restart
loop. Its existing generation checks and native stop path remain unchanged.
Already dispatched mail checks, pending connections and bounded watch cleanup can
still outlive the UI briefly; no new background interval or entitlement is added.

## Validation and installation

All **427 JavaScript tests and nine Python tests passed**. New deterministic
tests cover delayed index/Sent responses, repeated pulls, eventual companion
persistence, foreground/composer/navigation boundaries, one-time cached resume,
picture queue cancellation, consent races and actual ability callback hooks.

Three prepared native gates passed in the isolated app:

| Gate | Result |
| --- | --- |
| Encrypted cache | 9.514 s; 65 reversed headers across two chunks, dirty inclusion/exclusion, pagination, original offline body and close/reopen ordering. |
| Inbox latency | 28.286 s; two native pulls settle while one Sent page remains held, cached reader opens without body requests, and a background signal starts no successor. One client and three page requests. |
| Picture retry | 16.983 s; actual NetworkKit/ArkWeb downloads and replacement render; two HTTP 503 retries retain visible cached pixels, bytes, timestamp and consent. Four loopback requests. |

The native background check injects the same Inbox foreground signal used by the
ability; it is not a physical screen-lock or power measurement. Queued-picture
lifecycle coverage uses synthetic host tests. Selected native screenshots were
visually inspected. One initial emulator invocation exceeded the wrapper's
permitted duration and stopped before tests; the corrected bounded run passed all
three gates and stopped. Native-process absence was separately verified.

Production x86, signed ARM and isolated main/test HAPs built with SDK 26 while
retaining target/minimum API 22. All 52 shipping UI/data/mail/core/model files
match isolated staging; signed ARM source/library parity passed. Swift libraries
are unchanged from 0.1.15. The existing tablet split layout is unchanged.

Development 0.1.16 (100016) was installed in place and metadata/hash-verified on
Pura X and MatePad without clearing data or launching production. No real mailbox
access, physical mail screenshot or send occurred. AppGallery was not rebuilt.
Exact artifact and evidence hashes are in the
[validation record](../port/mail-corpus/release-0.1.16-validation.json).

Server authentication, header/preview fetching and logout still contribute to
actual refresh time. The existing IMAP error-classification and MIME/CID follow-ups
remain documented in the [previous review](review-performance-2026-09.md).
