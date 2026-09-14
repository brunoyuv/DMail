# Unicode decoding fixes — 0.1.1

The reported corruption affected both subjects/sender names and message bodies.
Synthetic tests reproduced faults in the original Swift MIME decoding path.
The port continues to use that Swift core, with these focused adaptations:

- Subjects and sender names can mix plain text with several encoded words.
  Folded whitespace between encoded words is handled correctly; Q-encoded
  underscores represent spaces, while literal underscores remain intact.
- Complete quoted-printable byte sequences are decoded before charset
  conversion. This preserves characters that span escaped and unescaped bytes,
  soft line breaks, or stateful encoding sequences.
- Base64 and quoted-printable bodies recover valid UTF-8 after an incorrect
  ASCII declaration fails. Correctly declared legacy encodings remain intact;
  invalid UTF-8 is not silently replaced or guessed.
- The local HTML document explicitly declares UTF-8, matching its Web response.
  Conflicting sender metadata cannot change the already-decoded document.
- A body decoder revision lets old saved bodies refresh once on an online
  read. Existing copies remain available offline. Newly decoded bodies retain
  their normal seven-day cache lifetime, including across inbox refreshes.

Validation used only synthetic/public fixtures. `scripts/test` passed 76 host
tests. `scripts/test-mime-port` passed 77 Swift MIME/account-body tests across
20 suites, including 17 public MIME corpus cases. Targeted regressions failed
before the native fixes and passed afterward.

The bounded `scripts/test-emulator-encoding` scenario passed exact subject,
sender, HTML, Shift_JIS and split quoted-printable expectations through the
shipping Swift core and NAPI. It also checked the displayed inbox/HTML reader
and revisited the cached message with zero new IMAP connections. The native
process exited and the emulator was confirmed stopped. Optional console-info
markers were absent from the collected system log; result collection was fixed
to use the named Hypium test's recorded success and fixture/capture checks.
The retained output was revalidated without repeating the emulator session.

Both production architectures and the isolated test HAPs built successfully.
The signed ARM package identifies itself as version **0.1.1**, code **100001**.
Native-library and source parity were checked. Package installation is recorded
in the [validation record](../port/swift-mime/utf8-validation.json).
The Pura X reported version 0.1.1 after an in-place upgrade; its original
installation timestamp was preserved. The production app was left closed.
MatePad was not connected.

The [synthetic reader screenshot](screenshots/utf8-reader.png) shows the tested
Unicode text. The user's real messages have not been inspected or tested.
