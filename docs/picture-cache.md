# Remembered message pictures

Keep the existing reader layout and Load pictures control. The first click saves
the choice for that message and account before downloading remote pictures.
Reopening the message, switching accounts and restarting the app restore that
choice automatically. Other messages retain their own permission.

The reader serves downloaded picture bytes from the encrypted account database.
It does not depend on the browser's cache and sends no mailbox credentials,
cookies or referring message URL to image hosts. Concurrent references share one
download. Missing images can retry on reopening without asking for permission
again. Existing cached images remain readable offline.

Picture bytes follow the existing seven-day cache retention, with an 8 MiB image
limit and 128 MiB per-account budget. Expiration does not erase the remembered
choice. Removing an account deletes its pictures and consent. Downloads that
finish after navigation remain attached to their originating account/message.

Installed 0.1.3 (100003) in place on Pura X and MatePad on 14 September 2026.
Both package versions were verified; production was not launched. All 111 host
checks passed, including eight SQLite/network cache cases and seven renderer
identity/consent cases. The emulator stayed stopped. Evidence is recorded in
`port/mail-corpus/picture-cache-validation.json`.
