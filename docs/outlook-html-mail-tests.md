# Dedicated Outlook HTML-mail tests — 2026-09-19

Subsequent user-requested implementation: [bounded MIME fetch batching](mime-fetch-batching.md).
The measurements and candidate-only assessment below describe the preceding round.

The saved test login can now be reused through the desktop Secret Service.
Live Outlook testing is **incomplete**: three synthetic self-mails received SMTP
acceptance, three other sends failed at authentication, and IMAP rejected the
receive checks. Six of the twelve messages remain unattempted. SMTP acceptance
does not confirm Inbox delivery. No failed or uncertain submission was replayed.

This round does not change shipping mail code, version 1.0.4, saved production
accounts, logging preference, or the installed Pura X package. No commit, push,
AppGallery build, MatePad update or production launch was performed. The earlier
Pura X installation is recorded in [imap-greeting-installation.json](imap-greeting-installation.json).

## Authorization and reusable test setup

The user explicitly authorized synthetic HTML send/receive tests with the
separate test mailbox and reuse of its login/snapshots. Messages are addressed
only to that same mailbox. Microsoft browser sign-in/consent remains user-operated.
The user completed a fresh grant; the original Swift OAuth bridge exchanged it
successfully. Tokens are stored only in the desktop Secret Service under an
exact account-scoped D-Mail test item. No password was saved.

The ignored `.tools/outlook-mail-tests/` harness imports credentials through a
private pipe. Its exclusive account lease serializes refresh, and the helper
persists replacement tokens before use. There are no tokens in command arguments,
environment variables, saved messages, public output or repository files.
`.tools/test-accounts/outlook/` records the local account identity and reuse scope.
Do not discard its `credential.lock` during a run.

The live sender links the original ported Swift SMTP implementation. Later
host-only instrumentation records closed SMTP stages, numeric reply codes and
elapsed times, never provider text or AUTH payloads. Authentication-only controls
stop immediately after `235`, before MAIL/RCPT/DATA. The same-address controls
preserve TLS certificate/hostname verification. These diagnostic changes are
confined to ignored host tools and are not shipping patches.

`send-ledger.json` is durably written before each submission. Every already
attempted message is skipped on subsequent diagnostic batches. Synthetic MIME,
HTML and sent-message snapshots remain ignored. Receiving matches both the exact
fixture Message-ID and subject before downloading a body, uses EXAMINE and PEEK,
and does not mutate mailbox flags or delete messages.

## Live authentication and delivery evidence

- Fresh browser token exchange and protected credential save succeeded. Swift
  IMAP failed specifically at authentication in 1.22 seconds.
- Independent Python IMAP also rejected that saved login. Independent Python SMTP
  authenticated with the same login, without sending.
- Six distinct Swift SMTP submissions produced three acceptances and three
  authentication failures. Two instrumented failures show server reply `535`;
  the first failure predates SMTP stage instrumentation. Accepted sends took
  approximately 14.30, 4.38 and 5.14 seconds, including connection/authentication
  and server DATA acceptance.
- Two independent SMTP EHLO controls succeeded. Two subsequent matched-address
  pairs also succeeded for both Swift and Python, with the same token, server
  address and EHLO name. Their complete authentication checks took 2.19–2.56
  seconds. Swift's trace places roughly 2.1–2.4 seconds in the AUTH exchange.
- Two later Swift receive checks failed at authentication before any Inbox/body
  access. No live received-body timing or end-to-end delivery result is claimed.
- The user checked Microsoft Recent activity and reported no blocked IMAP entry.

The saved token can authenticate to SMTP, and the same Swift sender can succeed
and fail without a credential or protocol change. These observations reproduce
intermittency but do not identify its root cause. SMTP success does not establish
IMAP permission. Neither the earlier greeting fix nor these controls prove that
all remaining failures belong to Microsoft or that shared OAuth assumptions are
correct for IMAP.

Microsoft documents the service endpoints and a Recent activity workaround for
some IMAP failures in [Outlook.com IMAP settings](https://support.microsoft.com/en-us/outlook/pop-imap-and-smtp-settings-for-outlook-com).
That workaround is not a confirmed remedy here. No automatic authentication retry,
credential reset, weakened TLS verification or production timeout change was added.

## Loading measurements

The corpus contains six pairs of singlepart HTML and multipart/alternative mail:
short note, newsletter, table, Unicode, quoted reply and long HTML. HTML sizes
range from about 0.5 KB to 263 KB. It does not include remote-picture downloads.

A temporary localhost TLS IMAP fixture served all twelve messages through the
original Swift `fetchReadable` and ported `EmailBody` decoder. Both zero-delay
and 50-ms-per-response runs passed, with exact decoded HTML equality and no
partial/decode errors. It uses a test certificate trusted only by the isolated
fixture client, dummy credentials and no live-account access. Both listener runs
were stopped after testing.

| Host receive measurement | Singlepart | Multipart alternative |
| --- | ---: | ---: |
| FETCH commands per body | 2 | 3 |
| Median download/assembly, zero injected delay | 2.44 ms | 3.49 ms |
| Median download/assembly, 50 ms per response | 102.80 ms | 154.25 ms |

These are one measurement per fixture per delay, summarized across six cases,
not repeated device latency measurements. MIME parsing/decoding used debug host
Swift objects, unlike optimized shipping native code; the long multipart fixture
needed about 16–17 ms for that separate decode stage.

The freshly compiled production HTML preparation functions were measured on the
host with five warmups and thirty samples per case. Maximum per-case median
preparation was 0.592 ms; the highest p95 was 1.742 ms. Maximum median reopening
of the warm prepared HTML file was 0.594 ms. The quoted-reply cases retained
`details` folding, cached bytes matched freshly prepared output, and script-free
CSP remained present. All 29 existing HTML-document tests passed.

These file measurements exclude HarmonyOS RDB/Asset access and ArkWeb layout,
paint, image loading and phone storage behavior. They are not app-open timings.

## Optimization assessment

1. **Reduce MIME round trips, after targeted regression testing.** The current
   reader requests BODYSTRUCTURE, then each selected MIME header/body pair
   separately. A bounded batch of selected parts is a measured candidate: the
   multipart alternative incurs one extra response and about 51 ms here. Combining
   its two part requests could remove that response, but that improvement has not
   been implemented or measured. Preserve root HEADER handling, exact UID binding,
   part/aggregate limits, partial-body behavior, cancellation and diagnostics.
2. **Keep the existing session and cache paths.** The foreground reader already
   reuses a serial, credential-bound Swift IMAP session. Foreground Inbox prefetch
   and durable prepared HTML avoid repeated authentication/download/preparation
   when valid cached mail is opened. Preserve their lifecycle, retention and
   reader-priority rules. The SMTP authentication timings show why unnecessary
   logins merit attention, but do not establish an IMAP-specific saving.
3. **Do not rewrite HTML rendering based on these results.** Preparation was cheap
   for this corpus. A device measurement and successful live IMAP transfer are
   still needed to attribute actual open latency. Reconnecting repeatedly or
   automatically replaying rejected/uncertain work would hide the present failure
   and can duplicate delivery; neither was added.

The next live gate is reliable IMAP authentication with the saved dedicated login.
Once it succeeds, retrieve the three accepted fixtures first and measure their
original-client download stages. Leave prior send identities in the ledger; do
not resend them to fill gaps.

See [the redacted validation record](outlook-html-mail-tests-validation.json).
The reusable scripts, source hashes, complete numeric traces and private synthetic
snapshots are under ignored `.tools/outlook-mail-tests/`.
