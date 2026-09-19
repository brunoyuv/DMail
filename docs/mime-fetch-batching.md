# Bounded MIME fetch batching — 1.0.4

The original Swift reader now fetches adjacent small MIME parts together.
A normal text/plain + text/html alternative needs two UID FETCH commands
(structure, then both parts), instead of three (structure, plain, HTML).

Pairs contain at most two already-selected parts, with a 512 KiB advertised
response budget that reserves 64 KiB for each MIME header. A larger part keeps
its existing separate request. This is a scheduling budget, not a new transport
byte limit; every actual returned section still passes the existing 64 KiB
header, 4 MiB content and 7 MiB aggregate validation. The original plan's part
count, size, topology and attachment rules are unchanged.

Each batch uses one awaited original Swift command and its existing cancellation,
TLS and timeout handling. Responses must identify exactly one target UID. Split
FETCH records, reversed section order and unrelated FLAGS are supported by the
existing response merger. Missing/invalid sections preserve valid siblings and
mark the result partial. Rejection, ambiguous identity or cancellation never
falls back to replaying individual requests. Root singlepart headers still use
BODY[HEADER]; multipart children still use their own MIME headers. Per-part
privacy-safe diagnostics remain available without changing the saved logging
preference.

## Validation

All 151 Swift tests pass (39 suites), including new planner boundaries and eleven
TLS response scenarios covering combined/split/reversed replies, missing content,
missing/malformed/oversized headers, foreign headers, wrong/duplicate/conflicting
UIDs and rejection without replay. All six download-diagnostic tests pass.

The same twelve synthetic HTML cases were run with the archived baseline and
updated client, alternating order across three runs. All 144 case executions
preserved exact decoded HTML without partial/decode errors. The localhost TLS
fixture injected either zero or 50 ms delay per response; no live Outlook
credentials or mailbox access was involved.

| At 50 ms per response | Before | After |
| --- | ---: | ---: |
| Singlepart FETCH count | 2 | 2 |
| Singlepart median download/assembly | 103.33 ms | 103.45 ms |
| Multipart alternative FETCH count | 3 | 2 |
| Multipart alternative median download/assembly | 154.73 ms | 104.10 ms |

That is about **33% less download/assembly time** for the tested multipart
alternatives under this controlled delay. Each table cell summarizes 18 samples
(six cases, three runs). Host objects are debug builds; this is not a phone,
ArkWeb paint, live Outlook or whole-app latency measurement. Larger pairs above
the budget intentionally retain separate requests.

Version and identities remain 1.0.4 / 1000004. The updated native cores were
compiled and linked for ARM64 and x86_64. At the user's subsequent request, the
signed development HAP is installed in place on Pura X with diagnostic marker
`1.0.4-mime-batching`. Installer success, signed input hash, installed version and
unchanged app/storage identities were verified. The app was not launched and
its process was absent after installation. The installed HAP was not read back;
prior OS access was denied. See [installation evidence](mime-fetch-batching-installation.json).
No commit, push or public release was performed. The earlier Outlook IMAP
authentication failure is separate and remains unresolved.

See [validation and source hashes](mime-fetch-batching-validation.json). Ignored
`.tools/fetch-batching/` contains the baseline source/binary, complete test logs,
before/after fixture records and benchmark runner.
