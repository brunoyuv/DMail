# Mail downloaded when opened

As of 0.1.26, mailbox refresh and background checks update headers and unread
state only. They do not register or resume the bulk body/picture queue. Selecting
a message uses its saved body first and downloads only that message if needed.
The downloaded body is saved to its original account. Obsolete queued selections
are cancelled; navigating away cannot publish the old result into another reader.

The explicit open prepares HTML once and completes one bounded picture attempt
before publishing a fixed reader view. An unfinished picture attempt can finish
on a later explicit open without rescanning HTML. Completed attempts, including
settled failures, are reused offline. Optional picture/preparation failures cannot
hide usable text. A failed body request exposes Retry instead of promising that
mailbox sync will eventually download it. Existing cache retention and tablet
split view remain unchanged.

New text, raw HTML and prepared HTML are readable files under the app-private
persistent `filesDir/mail-content` directory, as selected by the user. The
encrypted database keeps small metadata records and account-owned file references.
Header and flag changes preserve those references without body-file I/O. Legacy
inline bodies migrate on access, using bounded RDB reads for large records;
complete atomic files precede guarded reference updates. Missing raw-body files
allow explicit recovery, and failed migration preserves usable legacy content.

Automatic notification checks, initial IDLE establishment, arrival-triggered
header requests and companion-folder refreshes share a serial process-local
queue. It rests at least three seconds after an operation finishes, using a
nonblocking timer only when another operation is pending. Account/lifecycle
ownership is checked again after waiting. The configured check frequency stays
unchanged; the three-second rest does not create polling every three seconds.
Explicit opening, sending and manual refresh do not enter that queue.

## Historical bulk sync design (0.1.21–0.1.25)

The following describes the replaced implementation, retained as design history.

Mailbox sync downloads bodies and pictures before the user opens the messages.
Opening is local-only: the reader shows the saved HTML and whichever picture bytes
exist at that moment, including broken pictures. It does not scan the HTML, start
a download, offer picture Retry, or replace the open document when sync finishes.
This corrects 0.1.20, which prepared pictures during opening.

## Sync owns preparation

After a mailbox page is saved, its fetched message IDs enter a durable encrypted
backlog. Sync follows the mailbox pagination cursor through the remaining pages
without requiring Load more or opening a message. Initial cached mailbox loading
also registers every saved ID and resumes its traversal checkpoint. Inbox
refresh/IDLE arrivals, pagination and Inbox/Sent companion pages use the same
path. There is no 200-message admission limit or first-50 background slice.
Unfinished work survives app/store restarts and account switching. Header
feedback does not await body or picture downloads. The queue pauses new work
during backgrounding and user scroll/swipe interactions; an already active body
response may finish and save.

Bulk work rests between actual queued items: at least 250 ms at thermal level
COOL, increasing with the preceding work duration up to five seconds. At NORMAL
(getting warm), the rest is at least one second and twice the preceding duration,
up to ten seconds. WARM or hotter pauses new bulk work until a cooling callback.
The platform subscription is shared and released with the last worker. Devices
without the thermal API retain ordinary pacing. Empty and completed queues have
no polling timer. An unfinished request with a saved retry deadline schedules
one wake for that deadline; pauses and close cancel the wake and pending rest.
Restarting or resuming schedules it again from storage. This can
lengthen initial offline preparation while leaving header refresh independent.

The queue obtains a missing body through the existing mail client, using the
original Swift core for IMAP. Bounded sync sessions reuse TLS and authentication
for up to 16 reads, 60 seconds total or 15 seconds idle. Pause, failure and close
release these sessions; a failed exchange is not immediately replayed.
An existing fresh body, including partial or older decoder output, is retained.
Each protocol message ID needs its own saved body, even when a copy in another
folder shares an already prepared HTML document. This preserves attachment
metadata and reply text for both copies. Full body requests use the protocol
client's existing MIME selection and size/render bounds; preview text alone is
never a saved body. Usable partial content and valid empty bodies remain saved.
A decoding failure with neither text nor HTML stays pending with backoff.
Preparation finds picture references in HTML, CSS and SVG once, and saves the
complete prepared HTML with its stable local resource mapping in the encrypted
database **before** the picture batch starts. Good pictures are cached as they
arrive. A settled picture attempt records failures as well as successes, so later
syncs do not silently retry broken resources. Existing fresh documents are never
rescanned or rewritten. Failed body requests retry with increasing backoff, from
one minute up to one hour, only while the worker is permitted to run. They cannot
cycle immediately in the active drain or extend an OS background-job deadline.

The 0.1.24 upgrade repairs previously saved failed-empty bodies once, preserving
headers and summaries while making the missing body eligible for sync. It removes
only the exact empty prepared wrapper tied to that failed body's timestamp.
Successful shared documents and completed picture attempts remain intact.

An unusable document commit also enters durable backoff instead of bouncing
between body and picture stages. Invalid future-dated document records can be
repaired from a currently fresh body after clock rollback. This repair does not
replace a valid fresh document or cause the reader to reload.

Bodies and prepared documents take priority over pictures. A slow picture server
cannot prevent later messages' bodies from being saved. Durable stages and
guarded pagination advances let the next allowed sync continue after interruption.
Completed jobs retain their original body timestamp and do not renew retention
just because the same header page is seen again.

Scheduled jobs can perform the same work within their existing deadline and
account settings. They attach existing cache tables without migrations or pruning.
Their permission to download pictures is limited to that particular job; it does
not change the application's foreground flag or keep an IMAP IDLE socket alive
in the background. OS scheduling still controls when such jobs run.

## Opening a saved view

The reader obtains the prepared document and makes one local picture-cache read
when its saved document references pictures. A loading label identifies that
local wait; documents without picture references skip it.
It then mounts one Web with a fixed in-memory resource map. Missing resources
receive a blocked response and remain broken. Browser callbacks do no database
work, networking, scanning or loading-state updates. Foreground transitions only
pause/reactivate that same Web. Read/star acknowledgements update metadata while
preserving the body and document already being read.

If sync finishes while a message is open, its new bytes stay in storage; that open
view does not change. Reopening can display the newly saved bytes without scanning
or downloading. Legacy cached HTML without a prepared record can still display
inside a fixed security/style wrapper; the reader does not inspect or migrate it.
A never-downloaded body shows a pending-sync message, with no opening-time fetch.
Explicitly selecting a pending message again checks local storage for completion;
an already loaded reader remains fixed.

Browser networking and sender scripting are disabled. The prepared document's
content policy admits embedded images and intercepted local pictures only. Links,
quote disclosure, native dark adaptation, combined header/body scrolling and
tablet split navigation remain. This preserves HTML rendering rather than
rasterizing the message.

## Bounds and limits

The sync queue stores pending IDs on disk and selects bounded batches into memory;
it does not discard work after a fixed message count. Body requests are serialized.
Picture planning admits at most 256 distinct URLs and the batch retains at most 64 MiB of
encoded image data, with at most four concurrent downloads. New picture requests
stop starting after 30 seconds or the job's earlier deadline; active requests use
the existing connection/read timeouts. These are download-start deadlines, not
proof of zero remaining native work at that instant.

The existing seven-day retention is measured from body download. A fresh prepared
document is immutable; a normally expired one can be replaced only with a newer
downloaded body (invalid future timestamps use the repair above). Picture attempt markers survive byte expiry so expiration cannot silently
restart image downloads. Account deletion removes its prepared documents. Separate
attachments remain on demand. Unsupported or unresolved relative picture URLs
stay blocked; an incomplete image is not a reason to replace a saved document.

These changes remove opening-time preparation and incremental application updates.
They do not establish the user's heat cause or imply that native HTML layout,
image decoding and scrolling consume no CPU/GPU.
