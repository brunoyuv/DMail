# Experimental Swift runtime for HarmonyOS

This is platform toolchain work needed to reuse Thunderbird's Swift core. It
does not change Thunderbird source, and is not itself a Thunderbird port.

`scripts/build-swift-runtime` bootstraps Swift 6.2.3's standalone Core runtime
against Huawei's native x86-64 SDK. It uses the official Swift compiler, Huawei
C/C++ compiler and sysroot, and an explicit `x86_64-unknown-linux-ohos` target.
The source archive is pinned by its locally measured SHA-256. CMake 3.31.10 is
installed in a workspace virtual environment because the bundled Huawei CMake
is older than the runtime build's minimum version.

`harmonyos.patch` applies after upstream `Runtimes/Resync.cmake`. It:

- Excludes OHOS from the BSD `execinfo` library lookup.
- Applies the existing Linux exclusion of ObjectIdentifier debug descriptions
  to OHOS's CMake platform name.
- Omits Float80 and CLongDouble from this HarmonyOS-only standard library.
  Both Huawei clang and Swift's clang report `__LDBL_MANT_DIG__ == 113` for the
  x86-64 OHOS target: native long double is binary128. The upstream x86 Float80
  assumption would use the wrong C ABI. Swift has no corresponding Float128
  public type here; mapping this to Double or Float80 would be incorrect.
- Excludes the C++ Float80 formatting entry point on OHOS for the same reason.
- Links SwiftOnoneSupport with the native C++ driver, as swiftCore does, so
  Huawei's toolchain linker flags are understood.
- Propagates `swiftrt.o` to dependent native shared libraries in both the build
  and installed CMake exports. Without it, concurrency linked but a dynamic
  protocol cast failed because the library's Swift metadata was not registered.
- Applies the same native linker-driver selection to the regex libraries, and
  the binary128 restriction to the Musl floating-point bindings.

The constant false Swift guards intentionally survive textual module interface
emission. An earlier custom `-D` guard did not survive as a consumer build flag
and caused interface verification to fail. Interface verification is retained.
These sources are solely for the OHOS build; use a separate pristine checkout
for other platforms. This patch is experimental and has not been accepted upstream.

The bootstrap sets `CMAKE_Swift_COMPILER_WORKS=TRUE` because the normal compiler
smoke test needs the very standard library being built. It does not suppress
actual compilation, interface verification or linking. Installation runs only
after the build succeeds. Concurrency now uses a native build of libdispatch
and BlocksRuntime, and command-line support is enabled. The separate `dispatch-harmonyos.patch` uses the SDK's
exported `__progname` symbol and preserves const correctness. Foundation and networking are now
built separately. A successful Core build alone cannot compile Thunderbird's
Foundation imports or prove HAP integration.

Build logs are under `.tools/swift-probe/`, native build output under
`.tools/swift-ohos-runtime/`, and successful installation output under
`.tools/swift-ohos-sdk/`. See [the probe record](../../docs/swift-probe.md)
for measured results and remaining acceptance criteria.

Verified on 13 September 2026: the Core and OnoneSupport shared libraries build
and install successfully. `scripts/test-swift-runtime device` compiles a C/Swift
diagnostic for the native target and runs it from the emulator's development
temporary directory. It returned `SWIFT_OHOS_RUNTIME_OK`, checking a Unicode
round trip, character counting, array sorting, dictionary mutation, and Double
parsing/formatting. The executable dynamically loads the new `libswiftCore.so`;
its ELF dependencies are that library and native `libc.so`. The runtime itself
depends on native `libc++_shared.so` and `libc.so`. No Linux static SDK is used.
This narrow smoke test does not establish full Swift runtime correctness,
Foundation support, ARM-device support, or execution inside a HAP sandbox.

`scripts/test-swift-concurrency device` also passes on the emulator. It launches
a detached task, waits for 100 tasks to update an actor, checks the final count,
waits for a timer, and verifies that a cancelled sleeping task throws
`CancellationError`. A C semaphore gives the test a 15-second deadline. The
script requires the success marker because HDC's shell exit status can mask a
remote failure. This is not a test of ArkUI's main thread integration.

`scripts/build-swift-platform` builds the Musl binding, regex libraries, synchronization, ICU and musl-fts
from pinned sources. Additional archive provenance is in
`foundation-dependencies.json`; these are locally measured checksums of official
tagged archives. The C binding uses an umbrella module over Huawei's unmodified
headers instead of Swift's specially modularized Linux sysroot. The native
Foundation build is assessed separately; these dependency build results
must not be reported as Thunderbird integration success.

`scripts/build-swift-foundation` now builds and installs FoundationEssentials and
FoundationInternationalization. Its `foundation-harmonyos.patch` changes only
CMake language/link configuration, not Foundation's Swift implementation.
`scripts/test-swift-platform device` passes JSON Codable round trips containing
Unicode, URL host parsing, directory listing, regex match/rejection, mutex
mutation, process arguments and physical file-tree traversal. The full
`Foundation` and `FoundationXML` modules now build with `scripts/build-swift-foundation-compat`.
Replacing Thunderbird's import with FoundationEssentials was tested and rejected
because the string-trimming API is absent from that module.

`corelibs-harmonyos.patch` records the compatibility-library adaptations: native
linking and musl/include configuration, exclusion of the unsupported Float80
initializer, and the existing ENOSYS fallback for a missing spawn-directory
symbol. Swift Dispatch is built against one installed C module map. The `fts`
header is owned by `CFTS` and re-exported by the Musl binding.

`scripts/test-native-email device` now passes using the original Thunderbird
EmailAddress sources with **zero source patches**, native Foundation and a C
entry point. See [the native core record](../../docs/native-core.md). Networking
is disabled in this bootstrap build and remains required for the mail engines.
Separate HAP tests now verify original EmailAddress and MIME through Node-API,
including the composer UI and 13 upstream MIME fixtures. ARM-device support is
not yet proven. The optional [networking build](../../docs/native-networking.md)
passes six isolated HAP tests with system/app trust anchors, TLS rejection,
cancellation and repeated connection teardown. The production HAP now includes
FoundationNetworking and the original JMAP module for account discovery and
mailbox loading and plain-text reading; its five account-bridge and six
reader-bridge tests also pass, alongside six native message-change tests for flags
and archive/undo and five draft-creation tests. The networking patch also atomically
claims URLSession task completion before success/error callbacks to prevent a
continuation from being resumed twice during session cancellation. Twelve sequential
reader requests exercise that race regression. The connected composer remains unfinished. User CA policy, the
remaining mail-engine paths and ARM support remain unfinished.

The [musl-fts project](https://github.com/void-linux/musl-fts) supplies the NetBSD
file-tree traversal implementation for musl systems. Its source is unchanged;
`fts/CMakeLists.txt` performs the needed SDK feature checks and builds the library.
The original Autotools configuration rejected the OHOS host name. The CMake
adapter uses the Huawei OHOS toolchain directly without changing the target to
Linux musl. Its license is retained in `../../licenses/musl-fts.txt`.

The SDK's modern components install into `lib/swift/musl`; the upstream ICU and
Collections installers use `lib/swift/ohos`. Both contain OHOS-target artifacts.
Consumers currently pass the additional module search path explicitly; the
emulator test copies the required native libraries into one development folder.
