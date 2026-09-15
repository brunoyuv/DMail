# Mail loading and energy: findings and strategy

The user reported that a failed message load heats the device and requested an
online comparison of loading/receiving strategies. No real message was retrieved
for this investigation.

## Confirmed local defect

When an IMAP message has no usable server preview or text body, the reader
generates a preview from HTML. The inherited Swift tag-stripping expression
`/<[^>]*>/` repeatedly rescanned malformed, unclosed tags. In a synthetic
20,000-angle-bracket message, the actual preview path took 6,402 ms with the old
expression and 4.81 ms with the replacement forward scan. Rendering before that
preview remained approximately 35 ms in both cases. An 8,000-character case took
1,096 ms versus 2.20 ms.

The native bridge returns a timeout after 30 seconds and cancels its unstructured
Swift task. Cancellation does not interrupt a synchronous regex. This explains
how this class of defect can keep consuming CPU after the UI reports a failure;
it does not establish the contents or cause of the user's particular email.

The fix is an explicit patch to Thunderbird's original Account string helper.
It preserves character-boundary/Unicode behavior, unmatched markup and existing
whitespace normalization. All 103 MIME/account-body tests pass, including 1,000
small differential cases against the original expression. Both native
architectures were rebuilt for the update. Raw synthetic timing evidence
is in `.tools/failed-body-preview-cost.log`.

The ArkTS inbox excerpt also used repeated suffix searches for unfinished HTML
tags. Its replacement retains the existing 200,000-character input limit,
plain-text precedence, whitespace and Unicode behavior. A 60,000-character
synthetic unfinished-tag input fell from 513 ms to 1.71 ms; an unfinished
`head` input of 120,000 characters fell from 2,198 ms to 1.57 ms. These are host
timings of the actual helper, not device heat measurements.

The HTML reader had the same class of defect in tag and attribute scans. A
24 KB unfinished-tag fixture took 538 ms for preparation and 344 ms for remote
picture detection; forward source-span scans reduced those to 0.80 and 0.50 ms.
Long whitespace in attributes and CSS URL detection also had repeated searches;
their focused regressions now pass. Complete markup retains its original bytes
apart from the intended reader transformations, and an unfinished tag/quoted
suffix is left verbatim. Outputs matched the previous implementation on three
synthetic store HTML files and 200 combinations of valid fixtures. This is a
targeted fix for the measured paths, not a complete HTML parser or sanitizer.

## Strategies supported by primary sources

1. **Fetch only useful bytes.** IMAP supports server-provided `BODYSTRUCTURE`,
   individual MIME sections and byte ranges through `BODY.PEEK`. K-9 documents an
   initial download-size limit and explicit completion of larger messages.
   D-Mail already selects readable parts and fetches attachments on demand.
   Further improvement would deliver the text/HTML before optional inline images,
   validate server sizes, and enforce byte limits during transport rather than
   only after a section arrives. Preserve MIME alternative/related/CID scopes.
   [IMAP standard](https://www.rfc-editor.org/rfc/rfc9051.html#section-6.4.5),
   [K-9 download settings](https://docs.k9mail.app/en/6.400/settings/account/#fetch-messages-up-to)

2. **Share one load and end abandoned work.** Coalesce concurrent reads of the
   same account/message, cancel obsolete reads at navigation boundaries, and keep
   a total deadline in addition to per-command limits. The current UI rejects
   stale results but does not cancel every abandoned body request. Failed loads
   should not produce retries at multiple layers; any automatic retry needs a
   bounded count and increasing delay. The current reader has no automatic body
   retry loop. Its picture fix now suppresses repeated callbacks for a failed
   image until explicit Retry or a fresh reader attempt.
   [Retry guidance](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/rel_mitigate_interaction_failure_limit_retries.html),
   [Swift cancellation](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#Task-Cancellation)

3. **Keep CPU work bounded even off the UI thread.** The existing native IMAP and
   MIME bridge already uses N-API asynchronous work. Adding another worker around
   an expensive parser does not remove its energy cost. Prefer linear parsing,
   one final decode, limited concurrency and cancellation checks between chunks.
   HTTP image streaming can bound intermediate memory; destroying the request
   stops owned HTTP work. It does not replace the Swift IMAP transport.
   [Huawei loading-stage analysis](https://developer.huawei.com/consumer/cn/doc/doccenter-app-quality/bpta-web-completion-delay-analysis),
   [OpenHarmony HTTP streaming](https://github.com/openharmony/docs/blob/master/en/application-dev/network/http-request.md#initiating-an-http-streaming-request)

4. **Wait quietly for new mail.** Foreground IMAP IDLE avoids frequent full
   polling. Reconnect failures still need backoff, and IDLE must periodically be
   renewed. Thunderbird Android releases its wake lock while awaiting IDLE
   responses; its Android foreground service is not a HarmonyOS background
   entitlement. Keep Harmony background checks under the OS scheduler's power
   and temperature policy instead of maintaining an unsupported busy loop.
   [IDLE standard](https://www.rfc-editor.org/rfc/rfc2177.html),
   [Thunderbird IDLE implementation](https://github.com/thunderbird/thunderbird-android/blob/d4904c3fe879039bc349006d7d666f38d442c837/mail/protocols/imap/src/main/java/com/fsck/k9/mail/store/imap/RealImapFolderIdler.kt#L118),
   [Harmony scheduler constraints](https://github.com/openharmony/docs/blob/master/en/application-dev/task-management/work-scheduler.md#constraints)

## SDK comparison

The release 0.1.11 record already identifies CLI 26, compile SDK 26 and
target/minimum API 22. Recompiling the historical UI under CLI 26 therefore only
compares source versions. It cannot isolate compiler effects.

Huawei says only some behavior changes are gated by `targetSdkVersion`.
`compatibleSdkVersion` is the earliest supported version; neither proves
identical compiler behavior. A controlled comparison uses the same source,
fixture, native libraries, device and build mode under the two toolchains.
The device's installed ArkWeb engine must also be distinguished from the compile
SDK. Compiling with SDK 26 does not itself demonstrate an engine update on the
API 24 tablet. [Huawei upgrade guidance](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation)

The controlled comparison is now complete: the same picture-scroll fixture,
253 source/resource files and 24 imported native-library files were built with
SDK 22 and SDK 26. Both passed on the MatePad. Candidate reader scrolling used
4.534% versus 4.462% machine-normalized listed-process CPU, respectively; this
does not point to an SDK 26 regression in this scenario. Whole-device GPU was
22.737% versus 18.917%. These short sequential runs are not a battery-energy
comparison and cannot rule out other SDK-dependent behavior. The comparison
stages were frozen before the final malformed-HTML parser fixes.
See [the scrolling report](scroll-power-2026-09-15.md) for scope and reproduction.
