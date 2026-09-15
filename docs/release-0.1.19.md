# 0.1.19 — bounded HTML parsing and picture retries

Malformed, unfinished HTML tags could repeatedly rescan the remaining message
while generating its Swift preview or ArkTS inbox excerpt. These paths now
advance through the input once while preserving their existing text and Unicode
semantics. The reader's HTML transformations use source spans, preserving sender
markup while avoiding repeated searches over unfinished tags. This addresses
confirmed synthetic CPU stalls; the user's failed email was not retrieved, so
its exact cause remains unconfirmed.

The reader skips individual, clearly hidden remote images and unambiguously tiny
tracking images. Visible uses of the same URL, ambiguous stylesheet sizing, CID
images and ordinary content remain intact. One failed resource cannot repeatedly
restart its download through browser callbacks in the same reader attempt.
Explicit Retry remains available for genuinely missing pictures and clears the
attempt's failure memory. Successful cached pictures and timestamps are retained.

The existing tablet split view, native scrolling layout and synchronous
FIT_CONTENT reader are unchanged. Cached bodies are not refetched or rewritten
merely to apply these changes. The compile SDK stays at 26; minimum and target
API remain 22.

## Evidence and limits

The original Swift preview path took 6,402 ms for a synthetic 20,000-angle-bracket
message; the patched path took 4.81 ms. A malformed ArkTS inbox excerpt fell
from 2,198 ms to 1.57 ms. These are host CPU timings, not measured battery savings.

The MatePad comparison includes 1,500 HTML rows, 20 cached pictures and more than
220 rapid flings per 20-second phase. Neither picture downloads nor document
reloads occurred while scrolling. A controlled build comparison used identical
source/resources and imported native libraries under SDK 22 and 26. Candidate
listed-process CPU was 4.534% and 4.462% of the 12-core machine, respectively.
This scenario does not implicate SDK 26 and cannot rule out every SDK-specific
issue. The API comparison stages were frozen before the final parser fixes.

See [scrolling measurements](scroll-power-2026-09-15.md) and
[mail loading strategies with primary sources](mail-loading-energy.md).
Production mail was not opened, retrieved, captured or sent. Automated mail tests
use synthetic fixtures; charging-current readings are not app energy usage.

## Release gates

All 469 JavaScript tests across 47 files, 13 Python tests and 103 Swift MIME/body
tests across 24 suites passed. Both Swift native architectures were rebuilt.
Production x86/ARM and isolated main/test HAPs built successfully. The isolated
reader uses the same 53 copied production source files apart from two explicit
load counters; localized resources and the native core match.

The final bounded emulator run passed picture recovery and cache-only reopening:
the three visible resource request counts remained 1/3/3, and two clearly
non-content endpoints received zero requests. After all pictures were saved,
warnings and Retry disappeared; reopening with all endpoints unavailable issued
no requests. Synthetic screenshots were checked for the saved/recovered colors.

Native links preserved their query and fragment and reached the injected browser
opener exactly once; local anchors stayed in the message. The 1,500-row reader
then completed five drags over 12.6 seconds, kept one controller/document load,
reached 1,786 vp offset, and closed in 1,021 ms including test-driver work. The
isolated app was removed, the emulator shut down and its native process was
independently verified absent.

See [machine-readable validation](../port/mail-corpus/release-0.1.19-validation.json).
AppGallery packaging is outside this update.

Development 0.1.19 (100019) is installed in place on Pura X and MatePad. Both
bundle versions and the matching signed artifact hash were verified. Saved
accounts were preserved; production was not launched.
