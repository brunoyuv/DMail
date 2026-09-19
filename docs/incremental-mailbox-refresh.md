# Incremental mailbox refresh and seven-day local history

The user reported losing older loaded messages after refresh and asked for
incremental updates with less computation. Downloaded entries now stay in the
local folder for seven days from their saved arrival timestamp. Refresh absence,
even in an empty server response, does not delete them. Explicit confirmed moves,
deletions and account removal retain their existing behavior. This is a local
retention rule, not permission to delete mail from the server.

MailCache.saveView retains existing fresh entries and their folder membership.
Header/body saves preserve the entry's existing savedAt within that retention
period. Existing installations use the timestamp already in each record; an
earlier first-download time cannot be reconstructed. Expired entries are filtered
from views and removed by normal cache pruning. A real download after expiry can
admit the entry again with a new timestamp; merely retaining its ID cannot renew
it. Body and attachment-file lifetimes keep their existing separate bounds.

Manual, quiet and companion-folder refreshes merge the fetched head into loaded
rows. An unchanged server query state preserves the reached pagination position,
including the end. A changed state still uses the server's fresh cursor; no
positions or UIDs are guessed. Open reader content is not replaced by refresh.

Cache writes receive only the fetched headers separately from the retained view
order. Unchanged message payloads are not rewritten. Flags and confirmed mailbox
changes remain mutable; saved message bodies, HTML, pictures and attachment bytes
are not downloaded or rewritten by header refresh. Background header checks use
the same retention rule. The original Swift IMAP/JMAP clients remain unchanged:
this is incremental local application of the existing bounded server header
pages, not a new server-side delta protocol or a Git repository for mail.

Visible conversation rows are reused until messages, account, folder, search,
unread filtering, pending-operation revision or conversation revision changes.
This avoids repeating grouping/filtering for unrelated UI updates.

Synthetic evidence:
- 150 loaded entries survive manual refresh; Load more continues at 150 for an
  unchanged server snapshot. Quiet and companion-folder updates retain history.
- An empty refresh retains downloaded entries; explicit folder removal still
  works. Entries survive just before seven days and expire at the boundary.
- With 300 existing records, one new header and one changed flag produce exactly
  two message-row writes. Repeating those headers produces zero message writes;
  retained body metadata and files remain unchanged.
- With 2,000 messages, 100 unchanged visible-list evaluations reuse the same
  result with no additional identity scans. Relevant revisions invalidate it.

These are host work-count measurements, not device latency or battery results.
The local signed ARM build includes the changes. At the user’s subsequent
request, it was installed in place on Pura X on 2026-09-19, retaining version
1.0.5 (1000005), app identity, UID and storage/Asset identities. The input hash
and installer success were verified, and the app process was absent afterward.
No app launch, mailbox access or functional device test was performed. MatePad
and AppGallery were unchanged. The user subsequently requested consolidating
these changes into the 1.0.5 commit and publishing main to GitHub. Private
installation evidence is under ignored .tools/incremental-mailbox-install/.

Validation: all 864 JavaScript and 44 Python tests passed. Signed ARM HAP
source/native-library parity verification passed. Version remains 1.0.5.
Local candidate SHA-256: `172654ca6010c5af01493f52e522a0f2a0940f183682d0e82b6a277462e0a744`.
