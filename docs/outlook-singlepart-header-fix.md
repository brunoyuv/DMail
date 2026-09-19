# Outlook singlepart body header correction

The second user-uploaded diagnostic export, from
`1.0.4-download-log-2-detailed`, identifies a specific body rejection. Five
attempts for the same anonymous message successfully authenticate, select the
mailbox and fetch a singlepart `text/html` body advertised as 97,088 encoded
bytes, quoted-printable, UTF-8. Every attempt receives all 97,088 bytes in
`BODY[1]` and a tagged OK. No `BODY[1.MIME]` section is present. Validation
reports `missingHeader`; assembly then throws `mimeTypeImpossible` for its
omitted-part placeholder, which reaches the app as a generic network error.

This evidence supports a MIME-header request compatibility defect. It does not
establish that sender domains cause connection failure or that Microsoft is
throttling the account. One earlier attempt receives an uncoded authentication
NO; subsequent authentication succeeds. Every detailed failed attempt records
completed shutdown, with one active diagnostic request at entry and no timeout
or late completion. This capture does not demonstrate an accumulating socket
leak or explain every earlier reconnect symptom. The empty preview alone is not
proof of a failed body transfer: previews sample only the first 2,048 bytes.

After installation, the user confirmed that the email problem is fixed.

## Correction

On main, the original Swift client's readable-body plan now requests
`BODY.PEEK[HEADER]` together with `BODY.PEEK[1]` for a singlepart root. Root MIME
fields live in the message header. Child parts of multipart messages continue
using their numbered `.MIME` sections. On-demand standalone attachments use the
same root-header selection. This uses the original header and transport bytes,
without another FETCH, a retry, or invented encoding metadata.

The root HEADER form is defined in
[RFC 3501 section 6.4.5](https://www.rfc-editor.org/rfc/rfc3501.html#section-6.4.5).
Requesting the complete bounded header also avoids dependence on the spelling
and ordering of a returned HEADER.FIELDS selector. Existing 64 KiB header,
4 MiB part, aggregate-size, UID and mailbox-epoch checks remain in place. Headers
are parsed locally; diagnostic exports retain only categories and byte counts.

The package version stays **1.0.4 (1000004)**. Settings and diagnostic exports
identify this build as **1.0.4-download-log-3-singlepart-fix**. Detailed logging,
saved accounts, app/storage identities and on-demand body loading are preserved.
No commit, push or public release is part of this change.

## Validation

The synthetic local TLS regression deliberately omits `1.MIME`, sends every
advertised `BODY[1]` byte, and returns tagged OK. It covers both 80,407 and 97,088
bytes and password LOGIN/Microsoft XOAUTH2. Before the correction all four cases
fail with the same impossible omitted-part MIME type as the uploaded log. After
the correction all four pass, preserving exact encoded HTML bytes, HTML type,
quoted-printable encoding and UTF-8 metadata. Each uses one structure fetch and
one body fetch, then closes the connection.

The focused suite passes 46 Swift tests, including existing missing-header,
malformed-MIME, size-limit, target-UID, multipart/attachment, authentication,
repeated-failure and shutdown checks. The full host suite passes 795 JavaScript
and 40 Python tests. Tests use synthetic messages only. The uploaded log remains
in ignored local evidence, with no mailbox access or production UI automation.

Build and installation results are recorded in
[the validation record](outlook-singlepart-header-fix-validation.json).
Local evidence is under ignored `.tools/outlook-singlepart-fix/`.
