# 0.1.28 — bounded HTML scans

This follow-up is limited to the confirmed HTML processing problems. The user
set aside additional delays and background changes; automatic-work timing and
connection behavior remain as in 0.1.27.

Four HTML scans could repeatedly search the same malformed suffix: long failed
attribute names, unfinished opening tags, unfinished CSS `url()` calls, and
hidden-block removal for message previews. Doubling synthetic input roughly
quadrupled processing time. These are excessive scans, distinct from the
non-advancing entity loop fixed in 0.1.27; they can make a message appear stuck
after its network request has already finished.

The image and preview helpers now consume tokens with forward cursors, and
attribute matching cannot restart inside a failed name. MIME decoding still uses
the original Swift core. Normal image references, comments, quoted strings,
Unicode, preview text and output-size limits remain covered by regression tests.
The 0.1.27 entity patch and progressive reader behavior are preserved.

Optimized synthetic host results for the same inputs:

| Case | Before | After |
| --- | ---: | ---: |
| 4,000-character failed attribute name | 188 ms | 1.7 ms |
| 4,000 unfinished opening tags | 1,667 ms | 4.7 ms |
| 4,000 unfinished CSS calls | 725 ms | 3.2 ms |
| Preview removal with 4,000 unfinished tags | 591 ms | 3.0 ms |

All 112 Swift MIME/body tests passed under an external 30-second watchdog,
including four new malformed-input/cancellation tests. These measurements prove
the synthetic regressions, not the cause of every real-device heat report.
No real message contents or production UI were accessed.

The full host suite passed: 654 JavaScript and 32 Python tests. A focused review
also checked ten normal/malformed image cases and fifteen large Unicode cases
with bounded standalone probes. Both native architectures and production HAPs
rebuilt. The verified signed ARM package was installed in place on MatePad and
Pura X, with version and device identity checked, accounts preserved, and no
production launch. The emulator remained stopped.

Build and installation results are recorded in
[the validation record](../port/mail-corpus/release-0.1.28-validation.json).
