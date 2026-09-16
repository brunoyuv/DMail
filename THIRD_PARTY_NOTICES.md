# Third-party notices

D-Mail is an independent AI-assisted port/rework developed with OpenAI Codex.
Its original project source uses MPL-2.0 except where a component-specific
license is identified. Third-party code retains its original license and
copyright notices; inclusion in D-Mail does not relabel it as MPL-2.0.
AI assistance does not replace the upstream
authorship, copyright notices or component-specific licenses recorded below.

## Thunderbird for iOS

https://github.com/thunderbird/thunderbird-ios — Mozilla Public License 2.0.

The ArkTS prototype references Thunderbird's app flow and normalized email model. The Swift reuse probe compiles original EmailAddress and MIME sources and stages their upstream tests/resources without edits; its provenance is recorded in `port/swift-probe/upstream-files.json`. The full MPL-2.0 text is in `LICENSE`. The upstream source checkout is retained separately under ignored `upstream/`.

## Swift probe runtime

The official Swift 6.2.3 toolchain and static Linux SDK are local development dependencies under `.tools/`. The diagnostic static executable includes Swift/Foundation and SDK dependencies; it is not packaged in the production HAP. The SDK includes its own license files and SPDX bill of materials. Redistribution of a future runtime/HAP needs those notices to accompany the selected runtime components.

The experimental native runtime builds Swift 6.2.3 source under Apache-2.0 with
the Runtime Library Exception. Its original license remains in the downloaded
source tree. The platform patch in `port/swift-runtime/harmonyos.patch` includes
modified excerpts of that source and retains the same licensing terms.

Native FoundationEssentials and FoundationInternationalization are built from
swift-foundation 6.2.3 under Apache-2.0; the license is retained in
`licenses/swift-foundation.txt`. The source-only CMake patch retains those terms.
Swift Collections and Foundation ICU retain their own notices in the downloaded
source trees. The matching host Foundation macro plugin is used only during
compilation, not as a HarmonyOS runtime library.

The native file-tree traversal dependency is musl-fts 1.2.7, using the NetBSD
implementation under BSD-3-Clause. Its license is retained in
`licenses/musl-fts.txt`. The source is unchanged; a local CMake adapter replaces
the unsupported Autotools OHOS configuration. The native runtime and its required dependencies are now packaged in the development HAP.

The full native Foundation and FoundationXML compatibility modules use
swift-corelibs-foundation 6.2.3. Its license, including the runtime exception,
is retained in `licenses/swift-corelibs-foundation.txt`; the CMake/platform patch
retains those terms. libxml2 2.14.6 is built from GNOME's published source archive,
verified against its published SHA-256. Its notices are in `licenses/libxml2.txt`.
FoundationNetworking now builds with OpenSSL 3.5.8 (Apache-2.0, `licenses/openssl.txt`) and curl 8.22.0 (curl license, `licenses/curl.txt`). These networking libraries are packaged in the HAP and pass native networking/JMAP tests. The HAP includes the two original EmailAddress and 15 MIME source files unchanged, plus C ABI and Node-API adapters;
payload/source hashes are recorded in its generated provenance manifest.

## Original mail protocol and Account sources

The shared native core also compiles Thunderbird's 23 JMAP files, 43 IMAP files and three selected Account body-model files under MPL-2.0. Source manifests and explicit patches are retained in `port/swift-jmap`, `port/swift-imap` and `port/swift-accountbody`; the upstream notices remain in staged source files. The full Account module is not imported.

IMAP includes pinned SwiftNIO, SwiftNIO IMAP and NIOSSL, with Swift Atomics, Collections and System. Their available license/notice files are retained under `licenses/swift-*-license.txt` and `licenses/swift-*-notice.txt`. NIOSSL vendors BoringSSL; its upstream notice identifies the ISC/OpenSSL terms. Dependency revisions are recorded in `port/swift-imap/dependencies.json` and `Package.resolved`. HarmonyOS compatibility patches are explicit and keep upstream source headers.

## Huawei HarmonyOS application scaffold

The project scaffold is based on the application template bundled with `@deveco/deveco-cli` version `1.3.0-stable`. The CLI package is MIT licensed. Its generated ability source carries Copyright (c) 2026 Huawei Device Co., Ltd. and Apache-2.0 notices, which are retained. The app icon and preview mail content are newly created for this project.

DevEco CLI, HarmonyOS SDK, Hvigor and related tools are development dependencies installed under ignored `.tools/`; they are not redistributed with this repository.

The SMTP port includes the LineBasedFrameDecoder from Apple SwiftNIO Extras 1.24.0 (Apache-2.0), with the recorded error-type adaptation in `port/swift-smtp/vendor/source.json`. See `licenses/swift-nio-license.txt`. Thunderbird SMTP sources remain MPL-2.0; original hashes and platform patches are in `port/swift-smtp/`.

## Public email test corpus

The optional UI/MIME test corpus downloads 17 MIT-licensed MimeKit fixtures from
revision `d899a2a4cd5161117c6ebdc329152b973620474c`. Source URLs and SHA-256 hashes
are pinned in `port/mail-corpus/manifest.json`; the license is retained in
`licenses/mimekit.txt`. Downloads stay under ignored `.tools/mail-corpus/` and
are served only by the local test fixture. They are not shipped in the app.
The wide newsletter and 2.38 MiB PDF message are deterministic synthetic cases
created in this repository.

## Release-package runtime notices

Release bundles include these notices both alongside the HAP and in its raw
resources. Swift runtime terms are retained in `port/swift-runtime/LICENSE.txt`;
libdispatch terms are in `licenses/swift-dispatch.txt`; Foundation ICU wrapper
terms are in `licenses/swift-foundation-icu.txt`; Swift string-processing terms
are in `licenses/swift-string-processing.txt`. These texts are copied verbatim
from the pinned local dependency source checkouts. ICU 74.1's accompanying Unicode and third-party notices are in
`licenses/icu-74.1.txt`, copied from the matching
[ICU release](https://raw.githubusercontent.com/unicode-org/icu/release-74-1/LICENSE)
(SHA-256 `17510cf7a58b4879b887ec05a45d72cf1b73544dd9ec7e72f20110ed104229ee`).

The bundled native `libc++_shared.so` comes from the pinned Huawei API 22 native
SDK. Its LLVM runtime notices, including libc++, are retained verbatim in
`licenses/openharmony-llvm-NOTICE.txt`. SDK build tools themselves are not
redistributed. The project source remains MPL-2.0; each runtime component retains
its own license terms.

## Offline Markdown and math

MathJax 4.1.3 and its MathJax TeX font data and bundled WOFF2 fonts are distributed under Apache-2.0
(https://github.com/mathjax/MathJax-src and https://github.com/mathjax/MathJax-fonts).
Marked 18.0.13 remains **MIT licensed** (https://github.com/markedjs/marked),
copyright 2018+ MarkedJS and 2011–2018 Christopher Jeffrey. Its MIT permission
notice and the accompanying Markdown notices are retained verbatim. D-Mail's
MPL-2.0 license does not replace these terms.
Original licenses are in `licenses/mathjax.txt` and `licenses/marked.txt`.
D uses the unmodified Fira Math 0.3.4 font throughout its equations, under
**SIL Open Font License 1.1**, copyright 2018–2020 Xiangdong Zeng
(https://github.com/firamath/firamath). Its original font bytes are pinned in
`port/markdown-math/fonts/FiraMath-Regular.otf`; notices and the full license
are in `licenses/firamath.txt` and the app raw resources. Fira retains its OFL
license independently of D-Mail’s MPL-2.0.

For glyphs absent from Fira, D’s fallback MathML font copy adds native operator metrics and 16 display variants from
the upstream large-operator font, retaining the rule-thickness correction.
`port/markdown-math/build-mathml-font.py` documents the adaptation and verifies
original glyph outlines/advances and imported display shapes. The derived font
retains Apache-2.0. C continues to use the unchanged upstream font files.
The app-owned adapter, pinned package integrity, source hashes and reproducible
bundle instructions are in `port/markdown-math/`.

### HarmonyOS formula renderer under evaluation

`@cangjie-tpc/formula_hybrid` 1.3.2 is an evaluated alternative, not currently
an integrated or shipped dependency. Its OHPM metadata declares MIT, and its
archive's license identifies the formula code as **MIT licensed**, copyright
(c) 2020 Nano Michael. The same license file also contains Apache-2.0 terms;
the complete file is retained verbatim in
`port/markdown-math/licenses/formula_hybrid-1.3.2.txt` rather than treating the
entire archive and its bundled runtimes as MIT-only.

Source: https://gitcode.com/Cangjie-TPC/formula-ffi/tree/formula-ffi_hybrid_cangjie-plugin_5.1.1

If adopted, retain the upstream MIT copyright and permission notice in source
and app notices, along with all applicable runtime and font notices. Keep any
adaptations of MIT renderer source under MIT, with changes identified separately.
