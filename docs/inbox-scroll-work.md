# Inbox scrolling work after consolidated 1.0.5

The user reports lag while scrolling Gmail and Outlook. They clarified that this
is scrolling stutter, not an identified late message-download problem, and asked
to reuse fixed downloaded content. No live mail or device UI was accessed.

Two concrete sources of repeated work were found:

- Each row's area callback copied a shared Map of every previously measured row
  and assigned it to ConnectedMail @State. Executing the previous production
  callback for 2,000 synthetic rows copied 1,999,000 map entries and issued 2,000
  list-wide height-state assignments. MailListItem now owns a scalar height per
  row, so neither shared map copying nor list-wide height updates remain.
  Unchanged/sub-pixel measurements are ignored. Marker and swipe-panel geometry
  stays tied to the same measured content height.
- Inbox interaction callbacks called InboxPrefetch.update with the same header
  array, rescanning every loaded message. For 2,000 rows and 100 repeated updates,
  the regression observed 400,000 extra ID reads before the fix and zero after.
  New arrays and changed query states still admit new work. Unchanged arrays
  still check lifecycle/interaction permissions and resume when allowed.

Sender, preview and date strings are prepared when a keyed row is created;
render/layout callbacks reuse them. Language changes explicitly reformat dates.
Existing row keys are unchanged, so new read/star state, displayed headers and
conversation counts still update their row. This is not a promise of literally
one paint forever: native scrolling, resizing and real state changes still need
layout/painting. The original Swift clients, message-body preparation, stored
HTML/pictures, seven-day retention and pagination are unchanged by this patch.

The row component keeps the existing UI, IDs, accessibility text and action
callbacks. Parent operation guards and close-before-mutation remain in place;
compact layout, connection state, action permissions and Archive/Delete choice
are reactive scalar props. Immutable mail headers are not deep-copied through
@Prop during layout. The native enabled-binding regression follows the new
component boundary and still verifies opening mail during a header refresh.

Validation: all 869 JavaScript and 44 Python tests passed. The signed ARM HAP
compiled with SDK 26 / target 22 and passed source/native-library parity checks.
Tests cover independent row measurements, repeated stable measurements, prepared
text reuse, row identity and action bindings, prefetch admission and pause/resume.
These are host work-count measurements and build checks, not native frame-rate,
battery or proof that every reported stutter is fixed. At the user’s subsequent
request, this HAP was installed in place on Pura X. The input hash, installer
success, version and app/storage identities were verified. The app was not
launched and its process was absent afterward; no mailbox access or automated
scrolling test occurred. MatePad was unchanged. No commit, push or AppGallery
rebuild was performed during the implementation/install round. The subsequent
user request consolidates this source into 1.0.5 and rebuilds the AppGallery
release for upload; see release-1.0.5.md. Private installation evidence is under
ignored .tools/scroll-lag-install/.

Development version remains 1.0.5 (1000005). Candidate SHA-256: `3ab6279ec9dd03a38246b8c92faf1affb326be35ce489e006beac229c8264261`.
Private build/test evidence is under ignored .tools/scroll-lag/.
