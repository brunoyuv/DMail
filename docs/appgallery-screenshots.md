# AppGallery screenshots

Six original PNG captures of the D-Mail interface, in English and light mode:

[Open the labelled preview gallery](screenshots/appgallery/index.html).

| Device | Inbox | Combined conversation | Composer |
| --- | --- | --- | --- |
| Phone, 1080 × 2400 (20:9) | [01](screenshots/appgallery/01-phone-inbox.png) | [02](screenshots/appgallery/02-phone-reader.png) | [03](screenshots/appgallery/03-phone-composer.png) |
| Tablet, 2800 × 1840 | [04](screenshots/appgallery/04-tablet-inbox.png) | [05](screenshots/appgallery/05-tablet-reader.png) | [06](screenshots/appgallery/06-tablet-composer.png) |

The matching six-image upload bundle is generated locally at
`dist/D-Mail-appgallery-screenshots.zip`. The separate 1024 × 1024 app icon is
[d-mail-icon.png](images/d-mail-icon.png).

All people, addresses and messages are fictional. The tablet inbox previews the
original [HTML newsletter](../port/mail-corpus/store-newsletter.html). Both reader
screenshots show a three-message conversation: the [pottery invitation](../port/mail-corpus/store-workshop.html),
Alex's reply from Sent, and the studio's [HTML response](../port/mail-corpus/store-workshop-reply.html).
The Inbox row displays a count of three. Earlier messages are collapsed, the
outgoing card is labelled Sent, and the current response offers Show quoted text.
Messages are connected using Message-ID, In-Reply-To and References across Inbox
and Sent, with distinct thread IDs; grouping is not based on a matching subject.
The native test expands an earlier reply and folds it again, then expands and
folds quoted text before capture. Exactly one message body remains expanded.

The capture round exposed an inbox redraw race after asynchronously loading the
cached conversation index. The reader already linked the messages, but the
inbox's ordinary Map did not notify ArkUI after grouping completed. The UI now
publishes a conversation revision after rebuilding the index, and the row list
and counts observe that revision. The native capture gate checks the merged row
and count without a diagnostic-driven refresh or an extra settling delay.

The sample HTML has no external images, tracking, scripts or network dependencies.
It renders in the real ArkWeb reader; no interface or email content was painted
onto the screenshots afterward. The composer shows an unsent local draft.

The screenshots use the shipping UI components in the isolated
`org.thunderbird.harmony.imaptest` main HAP, with an in-memory service and an
encrypted cache containing only fictional data. The visible diagnostic banner
from other test fixtures is absent from this dedicated screenshot host. The
tests assert zero mail-service calls and never click Send. They do not exercise
live provider behavior or validate the release signature.

To recapture with the prepared x86 native dependencies:

```sh
./scripts/build-imap-test-app
./scripts/capture-store-screenshots
```

Build with the emulator stopped. The capture command runs the two screen profiles
sequentially through `scripts/with-test-emulator`, removes the isolated app,
restores the emulator configuration and verifies shutdown after each run. New
raw screenshots and native test logs appear in `.tools/store-screenshots/` for
visual review before replacing the published images.

See [capture evidence](../port/mail-corpus/store-screenshots-validation.json)
for dimensions, hashes, native test results and the captured application source.
Release signing remains a separate step; see [release packages](release-packages.md).
