# Accounts, offline mail and conversations

Design prepared before applying the conversation layout, 14 September 2026.

Keep the large Inbox title, native controls, existing spacing and blue unread
bar. Make the email address above the list a native account menu. Remember the
last visited account, including when it was opened offline. Search starts hidden
and appears only at the top of the list or while it contains a query.

Open saved folders and downloaded messages from the encrypted cache first.
Switching accounts or reopening the app must not discard them. Preserve the
existing seven-day retention. Pull to refresh requests updated headers; opening
an already downloaded body must not download it again. An interrupted flag
change may make flags uncertain, but it must not hide the saved body.

Group related messages by their actual Message-ID, References, In-Reply-To or
server thread identifier. Never merge messages merely because their subjects
match. Combine received and sent copies within the same account. Show a small
message count on a grouped inbox row. In the reader, use compact sender/date
rows for the other messages, with one message expanded at a time. Mark outgoing
messages with a restrained blue Sent label. Keep attachments, the current
message's Reply menu, and HTML in one scrolling column.

Fold explicitly quoted HTML and plain-text reply lines into a Show quoted text
disclosure. Use blue, green and purple for successive quote levels. Keep the
message's own content visible and retain remote-picture consent.

After SMTP accepts a send, retain a local full copy immediately. Gmail's known
server-side copy behavior must not cause a duplicate APPEND. Other IMAP accounts
save the same MIME message into the server's declared Sent folder. A failed or
uncertain Sent-copy save is reported separately from delivery and never causes
an automatic SMTP retry.

Apply read/unread, Star and Archive changes immediately in the interface, then
save their server acknowledgements to the captured account. Sending returns to
the inbox after local validation and durable draft saving; OAuth, SMTP and the
Sent copy finish while the user browses other screens or switches accounts.
These jobs continue while the app process is alive. Interrupted delivery stays
unconfirmed and is never replayed automatically.

Conversations combine downloaded messages and refreshed Inbox/Sent header
pages. Additional bodies download only when opened; this does not perform an
exhaustive historical search of the server.

Validate with synthetic host and bounded native emulator tests. Install the
signed upgrade without launching production mail or accessing real accounts.

Release 0.1.2 (100002) was installed in place on Pura X and MatePad on 14
September 2026, with saved accounts preserved and production left closed.
Validation: 95 host tests, 47 Swift upstream tests, six native navigation/storage
tests, five native Sent-copy cases and seven focused account-capture races
passed. The remaining tablet send-transition and cover checks were stopped at
the user's request to install first. Full evidence and limits are recorded in
`port/mail-corpus/accounts-conversations-validation.json`. The emulator is stopped.
