# Validation record

The historical ArkTS application checks below describe the prototype. The [native core](native-core.md) and [native JMAP](native-jmap.md) records now establish shared Swift core integration in the shipping HAP: five EmailAddress/MIME tests and 32 networking/JMAP tests. The duplicate ArkTS protocol implementation is confined to the test source set. The full mail application port remains incomplete.

Verified on 13 September 2026 with the local HarmonyOS 6.0.2 (API 22) phone emulator. This covers the offline preview and connected JMAP reading against a synthetic server. Real-provider interoperability remains unverified.

## Build and model checks

- `./scripts/build`: native ArkTS compilation and unsigned HAP packaging pass. The expected missing signing-profile warning remains; a physical-device build needs signing.
- `./scripts/test`: strict TypeScript compilation and 52 host tests pass: six preview mail-model tests, 37 historical JMAP protocol tests, four production facade checks and five cache-format tests. The script displays each named test.
- CLI lint returned no diagnostics but reported zero files checked, so it is not treated as proof of full lint coverage.

## Native smoke checks

The unsigned HAP installed successfully through HDC and `EntryAbility` launched. Native UI layouts and screenshots were inspected through DevEco CLI.

| Flow | Result |
| --- | --- |
| Inbox and reader | Verified native system titles, symbols, message layout, scroll area, and action bars in the Chinese device locale. Fixed missing toolbar icons and header alignment found during visual inspection. |
| Archive | Verified the selected sample message disappears from Inbox and Undo appears. |
| Undo | Verified the message returns and the Undo control disappears. |
| Reply | Verified the recipient and `Re:` subject are populated from the original message. |
| Done and restart | Saved a reply, force-stopped the app, relaunched, and verified the reply in Drafts. |
| Back and restart | Fixed initial reply autosaving, created a second reply, used native Back, force-stopped and relaunched; verified the second reply also remains in Drafts. |
| Crash reports | DevEco CLI reported no crash logs for `org.thunderbird.harmony.dev` after these checks. |

Screenshots: [Inbox](screenshots/inbox.png) and [reader](screenshots/message.png). They show actual emulator rendering, not mockups.

## Historical prototype and account UI checks

Fifteen instrumented device tests cover the test-only Remote Communication Kit adapter, secure account storage, recovery, and native account setup-to-reader navigation against a local synthetic server. The UI flow changes read/unread and star/unstar, then recovers by refreshing after the fixture applies a star and drops the response. Fixture-side evidence confirms the five exact keyword patches and two archive/undo membership patches with no write replay, refreshed mailbox/message data, no followed redirect, and rejection of the fixture's untrusted TLS certificate. Archive removes the synthetic message from Inbox; Undo restores it while retaining its original label and star. The empty Inbox and Undo control were visually inspected. Response limits and UTF-8 handling also pass. See [JMAP details](jmap.md) and [account verification](accounts.md).

The connected reader's native toolbar labels, symbols and fetched Unicode body were visually checked in the Chinese device locale. Localized labels are resolved through the hosting ability's resource manager so the same component also renders correctly in the separate test module. The fixture uses its own ability context for both database setup and cleanup; no synthetic account metadata, cached mail or credential is retained after the UI test. Native cache tests verify account isolation, encrypted database reopen, dirty-record exclusion, removal and schema-1 migration.

The offline UI test makes the server unavailable and restarts the test ability. Saved mailboxes, the Inbox list and its previously opened Unicode body remain readable, with a timestamp and disabled mutation controls. Refresh after restoring the server removes the saved-copy label and restores all three actions. The [offline reader](screenshots/connected-offline-fixture.png) was visually inspected. This tests ability restart and database reopen, not termination of the whole test-runner process or an OS restart.

Two native backend tests create and read a Unicode draft, then exercise a response dropped after draft creation. Fixture checks confirm separate Cc/Bcc and reply headers, exactly two creations for two explicit attempts, and zero submission calls. This validates the [draft creation protocol](drafts.md), not a connected composer or durable draft upload workflow.

## Still unverified

- Native search text entry and edited draft autosaving: Huawei's optional keyboard-service consent interrupted test input; the service was dismissed without accepting its agreements. Domain search/filtering is unit-tested, but a successful native input/search test is not claimed.
- Landscape: the emulator accepted a rotate command, but the captured app remained portrait. Rotation and adaptive split view still need validation.
- Dark mode, tablet/desktop sizes, screen-reader behavior, large text, and English-locale runtime rendering.
- Account setup and secure credentials are implemented and tested with local fixtures. Real-provider interoperability, incremental/background synchronization, cache eviction, sending, attachments, HTML mail, and background work remain pending. No email was sent during testing.
