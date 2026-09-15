# Porting notes

## Architecture correction

The user clarified that a new ArkTS implementation does not satisfy the requested port. The implementation table below records prototype work, not evidence of upstream source reuse. The shipping backend now uses original Swift modules through a native bridge: EmailAddress, MIME, JMAP, IMAP, SMTP and three Account body-model files. The earlier independent protocol implementation is confined to tests. See [upstream reuse](upstream-reuse.md) for the revised acceptance criteria.

## Source baseline

- Repository: https://github.com/thunderbird/thunderbird-ios
- Revision: `61c78d9ebe39ac5b61f31fce371bdfe8c001f7bf`
- Inspected: `Core/Package.swift`, `Core/Sources/Account/Email.swift`, `Folder.swift`, app `EmailListView.swift`, and the app's Design/Database documentation.
- Upstream is itself under development. Its inbox currently uses `TempEmail.sampleData`; the backend is not fully connected to its screens.

## Mapping

| iOS component | HarmonyOS approach | Current state |
| --- | --- | --- |
| SwiftUI / BoltUI | ArkUI Navigation, native controls, system resources | Implemented for preview flows |
| Account.Email | Platform-neutral Mail model; distinct local, message, thread and account IDs | Subset implemented; not a lossless IMAP/JMAP conversion |
| EmailListView / ReadEmailView | Native inbox and HTML reader | Real saved-account inbox, original-core JMAP/IMAP reading and flag changes |
| ComposeView | Native text inputs and editor, autosaved local drafts | Connected SMTP composition with encrypted drafts and uncertain-send recovery; Reply/Reply All implemented; attachments pending |
| Foundation local storage | ArkData Preferences for a small sample snapshot | Versioned, validated, serialized writes |
| SQLite mail database | ArkData relationalStore with migrations | Encrypted accounts and offline mail cache implemented, with schema migration; incremental sync pending |
| IMAP / SMTP using SwiftNIO | Original Swift client behind a native C/Node-API bridge | IMAP TLS login, separate email/login identity, listing, paging, reading and flag changes verified with local fixtures; SMTP TLS/STARTTLS sending implemented |
| JMAP / URLSession | Original Swift JMAP and FoundationNetworking | Account setup, reader, keyword actions and archive/undo connected; draft creation backend tested; live provider pending |
| Apple credential storage / OAuth | Asset Store credentials and browser-based OAuth | Token storage/recovery implemented; OAuth pending |
| WKWebView HTML reader | Safe HTML rendering with remote content blocked by default | HTML opens automatically in ArkWeb, with script and network access blocked |

## UI decisions

- Follow Huawei's [design guidance](https://developer.huawei.com/consumer/en/design/) and [design concept](https://developer.huawei.com/consumer/cn/design/concept/).
- Use HarmonyOS system color resources instead of recreating the iOS Bolt palette. System font sizing and native controls provide the platform behavior.
- Use `NavigationMode.Auto` for phone/tablet adaptation, and a bounded reading width on larger screens.
- Keep compose and mailbox navigation visible. Put secondary message actions in native menus.
- Clearly label the sample mailbox and local drafts. Do not show fake account connections, sync timestamps, or sent confirmations.
- Preserve stored data if parsing fails; expose a retry instead of silently resetting the mailbox.

## Remaining milestones

The original Swift IMAP and SMTP paths now support mailbox reading, flags and
sending. Test devices include the MatePad 12.2-inch running HarmonyOS 6.1 and the
reconnected Pura X running HarmonyOS 7.0. The latest reader/composer update
installed on the Pura X first, as requested. UI iteration uses bounded emulator sessions.
Reply and Reply All are connected, including recipient selection, quoted text
and threading headers. The user next prioritizes porting Thunderbird server discovery/settings for broad IMAP/SMTP
compatibility and exploring browser-based OAuth with real provider registrations.
Sent-folder upload, attachments, synchronization and the rest of the complete
application port remain unfinished.

1. Finish emulator/device validation: keyboard, rotation, split view, dark mode and screen-reader behavior. Phone rendering, navigation, archive/undo and reply persistence are verified in the [validation record](validation.md).
2. Add provider autoconfiguration and OAuth; extend the encrypted offline cache with bounded retention and incremental synchronization.
3. Verify the [connected JMAP flow](accounts.md) against a live provider, and add state synchronization, a connected composer with durable draft upload/recovery, and submission. Extend to IMAP/SMTP and JMAP parity.
4. Add thread views, Sent-folder upload, attachment handling, OAuth providers, offline operation queues and background sync.
5. Validate migration/recovery, large mailboxes and accessibility, then produce a signed device build.

Sending test email requires explicit authorization for its recipient and content; automated tests should use local fixtures/test servers.
