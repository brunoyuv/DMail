# MIME compatibility adaptations

All 15 original Thunderbird MIME source files remain in the shipping module.
`upstream-files.json` pins them; `harmonyos.patch` records changes to Body and Part.
The byte parser in PartParsing.swift preserves MIME payload bytes until the
selected charset is decoded, instead of requiring the entire message to be ASCII.
It unfolds headers, accepts a colon without a following space, supplies the MIME
text/plain default and recognizes multipart delimiters only on complete lines.
Input/header/part limits remain bounded. Duplicate content headers are rejected.

`header-decoding.patch` and `HeaderDecoding.swift` extend the original
`String.headerDecoded()` entry point to decode RFC 2047 words among plain text,
folded whitespace, Q-encoded spaces and IANA charset names. Each word's bytes
are decoded together. Malformed or unknown words remain visible instead of
discarding the whole subject or sender name.

`html-entities.patch` fixes the original entity decoder's non-advancing loop
for an ampersand without a later semicolon, including ordinary image query URLs
and plain preview text. Its scalar scan preserves literal malformed text and
valid entity decoding without repeatedly scanning the same suffix. The original
source attribution and pinned source hashes remain intact.

`test-mime-port` runs the upstream MIME tests plus byte/charset/CID regressions.
Two upstream test files have recorded adaptations: old canonicalized-length and
trimmed-whitespace assertions now verify exact transport-body preservation,
round-trip MIME headers and decoded attachment bytes. Source fixtures are unchanged.
The original unpatched feasibility probe remains reproducible separately.

The related Account EmailBody patch uses system charset mappings and preserves
readable siblings when an individual part cannot decode, marking that result as
partial. The IMAP bridge uses the original inline-image assembly. The specific
user-reported message still requires live device verification; synthetic fixture
success alone does not prove its contents decode correctly.

Text bodies now decode transfer bytes before charset conversion, including
multibyte/stateful quoted-printable text. A valid UTF-8 body can recover after
its declared charset fails; successfully decoded legacy encodings remain
authoritative. See [the UTF-8 fix and validation](../../docs/utf8-decoding.md).
