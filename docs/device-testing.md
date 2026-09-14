# Physical-device testing

## Current MatePad results

The current device is a Huawei MatePad 12.2-inch (MRO-W00). The user reports
HarmonyOS 6.1.0; HDC reports OpenHarmony-6.1.1.120, API 24, aarch64.
The shipping Swift core passed 12 SMTP checks, six JMAP reader regressions and
25 IMAP/account/body checks against local synthetic servers. The production UI
fixture also passed HTML rendering, saved-draft recovery, SMTP settings and
submission, composer dismissal and starting a fresh message. No real mail was
sent. The fixture app and forwarding were removed after each run.
See the [MatePad evidence record](../port/swift-smtp/matepad-device-result.json)
for source, core and test-log hashes. The final signed update installed successfully
on the MatePad after emulator UI verification; no further tablet UI test or
automatic launch was performed.

UI checks now use the emulator at the user's request. Build while it is stopped:

```sh
scripts/prepare-native-app
scripts/build-imap-test-app
scripts/test-emulator-mail-ui
```

The last command starts only a prepared UI test, captures the reader and composer,
and stops the emulator on success or failure. Physical-device protocol checks
remain available separately; routine UI iteration should not disturb the tablet.

## Historical Pura X results

On 13 September 2026, the development-signed ARM HAP installed and launched on a Huawei Pura X (VDE-AL00). The user reports HarmonyOS 7.0.0; HDC reports an aarch64 CPU and OpenHarmony-7.0.0.105. Four native EmailAddress/MIME checks passed on hardware, including all 13 original MIME fixtures and concurrent worker calls. The composer UI test was excluded to avoid disturbing the user's session.

The server omitted UIDNEXT in SELECT/EXAMINE. The adapter now explicitly requests STATUS with UIDNEXT, UIDVALIDITY and MESSAGES, rejects incomplete status, and rejects a changed mailbox identity or count before fetching. The Pura X now displays the live account's folders, message list and a plain-text message body.

The same Swift core packaged in the shipping app passes **25 ARM IMAP/account/body tests**, including the new missing-UIDNEXT fallback, stale/incomplete status rejection, TLS, paging, MIME reading and flag updates against synthetic servers. The UI fixture scenario is excluded from the phone run; no real-provider flag changes were made for verification. See [ARM evidence](../port/swift-imap/arm-device-result.json). The diagnostic app is removed and fixture connections/forwarding are closed afterward. The emulator stayed stopped.

The launch screen now shows the saved account's real inbox as the navigation root, retaining the previous large title, sender/date rows, unread dots, search and filter styling. Mailboxes → Accounts opens setup. Search is hidden initially and reveals when scrolling down; pulling down at the top uses native Refresh. Search filters loaded message summaries; SMTP sending and HTML reading are described in [Sending and HTML](sending-and-html.md); attachment presentation and background sync remain unfinished. The sample composer was removed from the production entry screen; its earlier emulator UI check is historical. The current native EmailAddress/MIME suite contains four tests.

## Build and sign

Keep the emulator stopped. The ARM SDK and application outputs are separate from x86-64 outputs:

```sh
./scripts/build-arm-sdk
./scripts/build-device-app
./scripts/deveco auth login
THUNDERBIRD_PROJECT_DIR="$PWD/.tools/device-app" ./scripts/deveco signature generate
```

After generating signing configuration, build from `.tools/device-app` using the local Hvigor wrapper and `HVIGOR_USER_HOME="$PWD/.tools/hvigor-home"` resolved from the repository root. `assembleHap --mode module -p product=default -p module=entry@default --no-daemon` produces `entry/build/default/outputs/default/entry-default-signed.hap`. Subsequent `scripts/build-device-app` runs preserve signing configuration while updating production sources. Signing files and account material stay in ignored `.tools/`.

`scripts/verify-arm-sdk` checks ARM ELF targets. `scripts/verify-device-app --signed` checks packaged native libraries and production source parity; HDC installation validates device acceptance of the signature. Neither static verifier claims device execution.

To build the optional native test module, use `module=entry@ohosTest`. After installing its signed HAP alongside the main app, the native-only selection is:

```sh
hdc -t DEVICE shell 'aa test -b org.thunderbird.harmony.dev -m entry_test -s unittest /ets/testrunner/NativeCoreTestRunner -s class ThunderbirdSwiftNative#original_email_address_validation_through_node_api,ThunderbirdMIMENative -s timeout 45000'
```

Use the HDC binary under `.tools/deveco-26/command-line-tools/sdk/default/openharmony/toolchains/`. Do not uninstall the main app to update it: that would delete local accounts and caches. The standalone shell Swift probe was denied execution on the phone; successful native evidence comes from the signed HAP tests. No security restriction was disabled.

Private local evidence: `.tools/pura-x-native-tests.log`, `.tools/device-app-signed-verification.json`, `.tools/arm-device-test-build.log`. Phone layouts may contain account information and must not be published.

Run prepared physical IMAP diagnostics with `HDC_TARGET=DEVICE scripts/test-device-imap`. Prepare the isolated app using `THUNDERBIRD_SWIFT_ARCH=aarch64 scripts/build-imap-test-app`, then generate its own signing profile using `THUNDERBIRD_PROJECT_DIR="$PWD/.tools/imap-test-app-aarch64" scripts/deveco signature generate` and build each signed HAP. The diagnostic must contain the identical shipping Swift core; it adds app-scoped fixture trust only to its own bundle.

The final gesture update is verified by an isolated native UI test on the Pura X using the exact production `ConnectedMail` component and shipping Swift core. A saved synthetic account opens at the inbox root with search hidden. Pulling down displays a new server-provided subject, proving an actual refresh; forward scrolling hides search and scrolling back reveals it. Fixture observations confirm no mail mutations and all connections closed. Reproduce with `HDC_TARGET=DEVICE scripts/test-device-imap gestures` after preparing/signing the test HAPs. This runner removes its diagnostic app and temporary forwarding on exit.
