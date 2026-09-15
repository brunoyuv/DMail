# Original Thunderbird SMTP port

`upstream-files.json` pins all eleven original SMTP source files. `scripts/prepare-smtp`
verifies them, copies them into the existing Swift package and applies `harmonyos.patch`
and `oauth.patch`. ConnectionSecurity and ByteHandler remain unchanged.

The recorded patch replaces Apple Network/NIOTS transport with SwiftNIO Posix and
adds lifecycle deadlines, verified TLS upgrade, capability/response validation,
one envelope for all recipients, safe DATA encoding and explicit delivery outcomes.
MessageSafety and TlsHandler are small port support files. The line decoder comes
from SwiftNIO Extras 1.24.0 with its origin, hashes and adaptation recorded in vendor/.

To edit an original file, stage the package, edit Sources/SMTP there, then regenerate
a unified diff against the pinned upstream file with a/Sources/SMTP and b/Sources/SMTP
paths. Do not silently modify the upstream checkout. The shipping core excludes the
diagnostic entry point and shares EmailAddress/MIME/NIO modules with IMAP.

The device test fixture never forwards messages. Test credentials and recipients
are synthetic. See [sending and HTML](../../docs/sending-and-html.md) for supported
behavior and current limits.

`oauth.patch` adds XOAUTH2 to the original SMTP authentication state machine.
An explicitly supplied bearer token selects XOAUTH2 and never falls back to a
password mechanism. Credentials are sent only after verified TLS and capability
discovery. Error challenges receive an empty response and cannot lead to sending.
See [browser OAuth](../../docs/browser-oauth.md) for native test evidence and the
remaining account setup, storage and live-provider work.
