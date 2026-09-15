# Scrolling power investigation — 15 September 2026

The user reported high battery usage primarily during fast scrolling and an APS
picture-download warning despite the visible pictures appearing complete. This
is a new, narrow investigation after the earlier three-round review ended.

## Completed text comparison

The authorized MatePad ran an isolated app with 1,500 synthetic table rows and
no network resources. The historical 0.1.11 renderer/helper are frozen with
source hashes. The same native reader layout surrounds the installed 0.1.18
renderer. A third, experimental async Web viewport is diagnostic only; it does
not preserve the production header-scrolling layout and is not shipping.

The first trial used moderate swipes. Following the user's correction, the
second completed trial used repeated 16,000 px/s flings with no inserted pauses:
218–221 gestures over 20 seconds per mode. Each mode also has five-second idle
and settling phases. Both production-style variants scrolled over 35,000 vp,
kept a single Web component, performed no document reload during scrolling, and
closed in 1.1–1.3 seconds including test-driver work.

| Rapid-scrolling mode | Listed CPU, machine % | Logical core equivalents | Whole-device GPU % |
| --- | ---: | ---: | ---: |
| 0.1.11 | 4.470 | 0.536 | 26.219 |
| 0.1.18 | 4.489 | 0.539 | 28.678 |
| Experimental async viewport | 6.711 | 0.805 | 29.065 |

These results do not show a text-only CPU regression between 0.1.11 and 0.1.18.
They do not establish the cause of the reported heat. The async experiment did
not provide evidence supporting a production switch. Native and Web scroll
observers also differ between those modes. The subsequent picture trials below
use the production-style layout in both modes.

The first rapid attempt reached its 100-gesture cap after nine seconds, so the
20-second-duration assertion correctly failed. Raising the cap to 400 allowed
the unchanged duration requirement to pass. The incomplete run is not included
in the comparison.

## Cached-picture comparison

The picture fixture adds 20 distinct, generated 800 × 450 static PNGs to the
1,500-row document, plus two visible unavailable images and two explicit
one-pixel tracking images. The PNGs total 28,800,000 decoded RGBA bytes; the HTML
is under 1 MB. No real mail or external image service is involved. Each scene
primes its encrypted picture cache from a loopback server before measurement,
then changes the saved-image endpoints to counted HTTP 503 responses so an
unwanted refetch is detectable. Saved bytes and timestamps are checked again
after scrolling.

The frozen 0.1.18 renderer (`baseline018`) and the picture-failure memo/tracker
candidate (`current019`) each run five seconds idle, 20 seconds of repeated
16,000 px/s flings, and five seconds settling. Both retain the same native
reader wrapper. This candidate snapshot precedes the final malformed-HTML
parser fixes; these results are not measurements of the final release build.

Both completed SDK trials preserved all 20 saved pictures and their timestamps.
Every measured phase had zero additional renderer resource callbacks, picture
cache API calls, or loopback HTTP requests, including the two unavailable
pictures. Thus this fixture did not reproduce repeated failed-image requests
during scrolling in either renderer, and it does not establish a CPU saving
from the failure memo. During initial scene loading, 0.1.18 requested both
one-pixel trackers; the candidate filtered both before requesting them. Initial
resource/cache call counts were 24 for 0.1.18 and 22 for the candidate.

The first SDK 26 picture attempt passed the phase and saved-picture assertions
but failed the candidate's three-second Close deadline. It did not log the
actual Close duration before failing, so the cause cannot be assigned from
that attempt. It is excluded from the metric comparison. Test-only timestamps
were then added at the native button handler and the closed view's appearance,
with logging before the unchanged three-second driver assertion. The
instrumented SDK 26 rerun and SDK 22 trial both passed: native Close took
45–48 ms, while the full driver operation took 970–1,114 ms. Both modes kept
one Web component and unchanged document/controller load counts during the
flings, with observed scroll offsets above 34,000 vp.

## Controlled SDK 22 / SDK 26 comparison

The earlier text comparison compiled all renderer versions with SDK 26, so it
could not separate a toolchain effect. For this comparison, the prepared ARM
picture-test project was copied to an isolated SDK 22 directory. Its 253
source/resource files and 24 imported native-library files were verified
byte-identical before and after the build. The imported Swift core remained
the frozen benchmark library, with SHA-256
`1c074e12a6c71d2e0f563c7df7145c841a8b74c9b8eb6c2a2111ed4a8a238e91`.
It was not replaced by the subsequently rebuilt release core.

| Build input | Previous toolchain | Current toolchain |
| --- | --- | --- |
| Command-line tools | 6.0.2.670 | 26.0.0.821 |
| Hvigor / plugin | 6.22.9 / 6.22.9 | 6.26.4 / 6.26.4 |
| Node.js | 18.20.1 | 24.14.1 |
| Compile SDK | 6.0.2.130 (API 22) | 26.0.0.105 (API 26) |
| Minimum / target API | 22 / 22 | 22 / 22 |

The SDK 22 copy removed only the compile-SDK override from the project profile;
the remaining profile values were preserved. Each build used its own compiler
and dependency cache; the previous toolchain used pnpm 10.27.0. Package metadata
confirmed the different compile SDKs and unchanged minimum/target API. Compiled
ArkTS bytecode differed. The two C++ bridge libraries, `libthunderbird.so` and
`libimaptest.so`, were rebuilt by each SDK and differed; the imported Swift and
native libraries did not. This compares the toolchains as a whole, including
their bridge builds. Source, artifact and log hashes are recorded in the
public metric record; detailed local parity records remain in ignored `.tools/`.

Each row below has 19 accepted, fully contained scrolling samples. SDK 26 ran
223 flings per mode; SDK 22 ran 221–222, each over at least 20 seconds.

| Compile SDK / renderer | Listed CPU, machine % | Logical core equivalents | Whole-device GPU % | Reported FPS |
| --- | ---: | ---: | ---: | ---: |
| 26 / frozen 0.1.18 | 4.457 | 0.535 | 18.637 | 120.000 |
| 26 / picture candidate | 4.462 | 0.535 | 18.917 | 119.841 |
| 22 / frozen 0.1.18 | 4.519 | 0.542 | 20.060 | 119.895 |
| 22 / picture candidate | 4.534 | 0.544 | 22.737 | 119.947 |

SDK 26 did not show higher listed CPU use than SDK 22 in this bounded static
picture test, and both were responsive. This does not rule out an SDK-related
problem in other content or app activity. These are sequential trials with one
completed run per toolchain, different starting temperatures and no randomized
repetitions. Mean SoC temperature during scrolling was 51.7–52.8 °C, falling
during settling; these sensor values do not attribute the user's heat or
battery-share report to a particular component. Animated images, malformed
documents, background work and real inbox refresh are outside this fixture.

## Measurement limits and reproduction

SmartPerf CPU percentages divide runtime by elapsed time and the number of
logical CPUs. The tablet reports 12: 8.333% is approximately one occupied logical
CPU. The listed main/child PIDs are not proof of complete ArkWeb process
coverage. GPU utilization is for the whole device. The tablet was charging;
signed battery-current samples cannot establish app watts, energy, or a share
of battery use. The record retains signed current and voltage in the original
SmartPerf raw units, without conversion to application power.

The offline parser excludes the initial collector sample, accepts only complete
750–1,500 ms sample intervals within each phase, and omits the first second of
settling. Missing values remain missing. It rejects incomplete or failed tests.
The [public metric record](../port/mail-corpus/scroll-power-2026-09-15.json)
contains compact results and input hashes. Raw synthetic performance logs stay
under ignored `.tools/`.

Use `DMAIL_HTML_SCROLL_POWER_TRACE=1 scripts/prepare-imap-test-app` with the ARM
target, build both isolated signed HAPs, then run `scripts/test-html-scroll-power`
with both explicitly authorized MatePad target variables. The launcher validates
model/architecture, brings the isolated blank page forward, performs finite
sampling, stops and removes the test app, and never opens production mail.
Set `DMAIL_HTML_POWER_SCENARIO=pictures` for the picture runner. After preparing
the separate matched SDK 22 build, `DMAIL_HTML_POWER_SDK=22` selects it; the
default remains SDK 26. `scripts/summarize-html-scroll-power` correlates the
resulting logs and CSV; use `--modes baseline018,current019` for either picture
trial. The SDK comparison's local source and build validation records are
`.tools/sdk22-scroll-comparison-source.json` and
`.tools/sdk22-scroll-comparison-build-validation.json`.

Primary references: [OpenHarmony rendering modes](https://github.com/openharmony/docs/blob/master/en/application-dev/web/web-render-mode.md),
[HiView CPU calculator](https://github.com/openharmony/hiviewdfx_hiview/blob/master/framework/native/unified_collection/collector/impl/cpu/calculator/cpu_calculator.cpp),
and [SmartPerf metrics](https://github.com/openharmony/docs/blob/master/en/application-dev/application-test/smartperf-guidelines.md).
