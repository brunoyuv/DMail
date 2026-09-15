// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { validateEmailAddress } from 'libthunderbird.so';
import { common } from '@kit.AbilityKit';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { JmapService, JmapClientFactory, JmapCredentials, JmapAccount, JmapMailbox, JmapEmail, JmapError,
  JmapKeyword, canSetKeyword, archiveTarget, JmapArchiveUndo, MailAttachment, MailAttachmentData, JmapAddress, shallowCopyEmail } from '../mail/jmap/JmapClient';
import { AttachmentFiles } from '../mail/attachments/AttachmentFiles';
import { OutgoingAttachmentFiles } from '../mail/attachments/OutgoingAttachmentFiles';
import { OutgoingAttachment, outgoingAttachmentReference, outgoingUUIDValid } from '../mail/attachments/OutgoingAttachmentModel';
import { MailCache } from '../data/MailCache';
import { PreparedMailDocument } from '../data/PreparedDocumentModel';
import { MailMessageLoader, MailMessageLoadCancelled } from '../mail/MailMessageLoader';
import { AutomaticMailWork, AutomaticMailWorkCancelled } from '../mail/AutomaticMailWork';
import { MAILBOX_ROLE_REVISION } from '../data/MailCacheModel';
import { conversationMessages, conversationGroups, stableMessageKey } from '../mail/Conversation';
import { plainTextMailHtml } from '../mail/html/HtmlDocument';
import { MailOperations } from '../mail/MailOperations';
import { BackgroundSend } from '../mail/smtp/BackgroundSend';
import { LOCAL_SENT_MAILBOX, serverSentMailbox } from '../mail/smtp/SentMail';
import { replyContent, forwardContent } from '../mail/smtp/Reply';
import { OutgoingDraft, SmtpSettings } from '../mail/smtp/NativeSmtpClient';
import { NativeMailDiscovery, MailDiscoveryService, MailConfiguration, DiscoveredServer, DiscoveryError } from '../mail/discovery/NativeMailDiscovery';
import { ComposeMail } from './ComposeMail';
import { DeferredSave } from './DeferredSave';
import { HtmlMail } from './HtmlMail';
import { Settings } from './Settings';
import { AppLanguage } from '../settings/AppLanguage';
import { HarmonyMailClientFactory } from '../mail/HarmonyMailClientFactory';
import { LoopbackBrowserSignIn } from '../mail/oauth/LoopbackBrowserSignIn';
import { MailOAuthProvider } from '../mail/oauth/NativeBrowserOAuth';
import { RegisteredMailOAuth, SavedOAuthLogin } from '../mail/oauth/RegisteredMailOAuth';
import { oauthFailureLabel, oauthFailureCode } from '../mail/oauth/OAuthFailure';
import { MailNotificationService } from '../mail/notifications/MailNotificationService';
import { NotificationPlatform } from '../mail/notifications/NotificationPlatform';
import { MailInboxUpdates } from '../mail/notifications/MailInboxUpdates';
import { MailUnreadStatus } from '../mail/MailUnreadStatus';
import { NotificationInboxPrompt } from './NotificationInboxPrompt';
import { MailBannerNotice } from '../mail/notifications/MailBannerNotice';
import { MailBadgeService } from '../mail/notifications/MailBadgeService';

class TokenCredentials implements JmapCredentials {
  username?: string;
  private token: string;
  private scheme: string;
  constructor(token: string, scheme: string = 'Bearer', username?: string) { this.token = token; this.scheme = scheme; this.username = username; }
  async authorization(): Promise<string> { return `${this.scheme} ${this.token}`; }
}

@Component
export struct ConnectedMail {
  openInboxOnLaunch: boolean = false;
  clientFactory: JmapClientFactory = new HarmonyMailClientFactory();
  accountStore: AccountStore = new AccountStore();
  discoveryService: MailDiscoveryService = new NativeMailDiscovery();
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @StorageLink('mailOperationRevision') @Watch('operationsChanged') private operationRevision: number = 0;
  @StorageLink('mailSendRevision') @Watch('sendChanged') private sendRevision: number = 0;
  @StorageLink('mailNotificationOpenRevision') @Watch('openNotification') private notificationRevision: number = 0;
  @StorageLink('mailInboxUpdateRevision') @Watch('inboxChanged') private inboxUpdateRevision: number = 0;
  @StorageLink('mailNotificationSettingsRevision') @Watch('unreadChanged') private unreadSettingsRevision: number = 0;
  private unreadForeground: boolean = false;
  @StorageLink('mailUnreadRevision') @Watch('unreadChanged') private unreadRevision: number = 0;
  private unreadRefresh: Promise<void> = Promise.resolve();
  private inboxAcknowledged: Map<string, number> = new Map();
  private inboxRequests: Map<string, Promise<boolean>> = new Map();
  private inboxCachedUpdates: Set<string> = new Set();
  private inboxFetching: Set<string> = new Set();
  private inboxTimer: number = -1;
  private inboxAnchorTimer: number = -1;
  private inboxLoadRevision: number = 0;
  private mailboxRefreshRevision: number = 0;
  private inboxViewRevision: number = 0;
  private inboxRetryKey: string = '';
  private inboxRetries: number = 0;
  private inboxRetryAt: number = 0;
  private inboxScrollActive: boolean = false;
  private inboxPullActive: boolean = false;
  private inboxScrollRevision: number = 0;
  private inboxFirstVisible: number = 0;
  private inboxSwipes: Set<string> = new Set();
  private openingNotification: boolean = false;
  private active: boolean = true;
  private boxRolesCurrent: boolean = false;
  private sentFolderUpdates: Set<string> = new Set();
  private conversationById: Map<string, JmapEmail[]> = new Map();
  private conversationLoadRevision: number = 0;
  private conversationIndexPending: boolean = false;
  private conversationRefreshes: Map<string, number> = new Map();
  @State private accounts: SavedAccount[] = [];
  @State serverUrl: string = '';
  @State token: string = '';
  @State protocol: string = 'imap';
  @State username: string = '';
  @State emailAddress: string = '';
  @State port: string = '993';
  @State private discovered: MailConfiguration | null = null;
  @State private incomingChoice: number = 0;
  @State private outgoingChoice: number = 0;
  @State private smtpEndpoint: string = '';
  @State private smtpUsername: string = '';
  @State private smtpSamePassword: boolean = true;
  @State private candidates: JmapAccount[] = [];
  @State @Watch('inboxChanged') private busy: boolean = false;
  @State private ready: boolean = false;
  @State private compact: boolean = false;
  @State private rowContentHeights: Map<string, number> = new Map();
  @State private tablet: boolean = false;
  @State private readerCompact: boolean = false;
  @State private readerDetails: boolean = false;
  @State private error: ResourceStr = '';
  @State private account: SavedAccount = new SavedAccount();
  @State private query: string = '';
  @State private searchVisible: boolean = false;
  @State private refreshing: boolean = false;
  // Native Refresh can dismiss its indicator on an upward gesture before the
  // request finishes. Gesture-owned feedback is not network ownership.
  @State private mailboxRefreshActive: boolean = false;
  @State private unreadOnly: boolean = false;
  @State private boxes: JmapMailbox[] = [];
  @State private boxName: string = '';
  @State private emails: JmapEmail[] = [];
  @State private selected: JmapEmail | null = null;
  @State private conversationIndex: JmapEmail[] = [];
  @State private conversationRevision: number = 0;
  @State private conversation: JmapEmail[] = [];
  @State private bodyLoaded: boolean = false;
  @State private attachmentBusy: string = '';
  @State private attachmentError: string = '';
  @State private nextPosition: number | null = null;
  @State private readOnly: boolean = true;
  @State private changing: boolean = false;
  @State @Watch('inboxChanged') private swipeClosing: boolean = false;
  private pendingSwipeAction: (() => void) | null = null;
  @State private refreshRequired: boolean = false;
  @State private archiveUndo: JmapArchiveUndo | null = null;
  @State private moveNotice: string = '';
  @State private savedCopyAt: number = 0;
  private savedCopyFromDirty: boolean = false;
  @State private cacheWarning: boolean = false;
  private selectedId: string = '';
  private boxesDirty: boolean = false;
  private emailsDirty: boolean = false;
  private paths: NavPathStack = new NavPathStack();
  private client: JmapService | null = null;
  private messageLoader?: MailMessageLoader;
  private inboxVisible: boolean = true;
  @State private readerVisible: boolean = false;
  private readerScrollActive: boolean = false;
  @State private readerDocument: PreparedMailDocument | null = null;
  @State private mailboxId: string = '';
  private queryState: string | undefined = undefined;
  private generation: number = 0;
  private mailScroller: ListScroller = new ListScroller();
  private searchInteracted: boolean = false;
  private oauthFlow?: LoopbackBrowserSignIn;
  @State private oauthPending: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.inboxVisible = this.openInboxOnLaunch; this.readerVisible = false;
    AppLanguage.load(this.getUIContext().getHostContext() as common.Context);
    this.initialize();
  }
  aboutToDisappear(): void {
    if (this.inboxTimer !== -1) { clearTimeout(this.inboxTimer); this.inboxTimer = -1; }
    if (this.inboxAnchorTimer !== -1) { clearTimeout(this.inboxAnchorTimer); this.inboxAnchorTimer = -1; }
    ++this.inboxLoadRevision; ++this.mailboxRefreshRevision; MailNotificationService.setVisibleAccount('');
    this.mailboxRefreshActive = false; this.refreshing = false;
    this.pendingSwipeAction?.();
    this.inboxVisible = false; this.readerVisible = false;
    this.retireInboxInteraction(); this.readerScrollActive = false;
    this.active = false; ++this.generation; this.oauthFlow?.cancel(); this.token = ''; this.client = null;
    this.messageLoader?.cancel(); AutomaticMailWork.cancelInactive();
    const loading = this.messageLoader?.whenIdle() || Promise.resolve(); this.messageLoader = undefined;
    const generation = this.generation;
    // Flushing a composer can start a send. Observe its idle barrier only after
    // those saves finish, otherwise a previously idle snapshot closes the store
    // underneath the newly queued preflight.
    DeferredSave.flushAll().then(() => Promise.all([MailOperations.whenIdle(), BackgroundSend.whenIdle(), loading, this.unreadRefresh, ...Array.from(this.inboxRequests.values())]))
      .then(async () => { if (!this.active && generation === this.generation) { await this.accountStore.close(); } }).catch(() => {});
  }

  private label(name: string): string {
    this.languageRevision;
    // Resolve against the hosting ability, including when this component is
    // embedded in another module. Native toolbar items need concrete labels.
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }

  private async initialize(): Promise<void> {
    const generation = ++this.generation;
    let lastAccount: SavedAccount | null = null;
    this.busy = true; this.error = '';
    try {
      await this.accountStore.open(this.getUIContext().getHostContext() as common.Context);
      this.messageLoader = new MailMessageLoader(this.accountStore);
      const context = this.getUIContext().getHostContext()!;
      await AttachmentFiles.prune(context.filesDir).catch(() => {});
      await AttachmentFiles.prune(context.cacheDir).catch(() => {});
      const accounts = await this.accountStore.list();
      lastAccount = await this.accountStore.lastVisitedAccount();
      if (generation === this.generation) { this.accounts = accounts; this.ready = true; }
    } catch (_) { if (generation === this.generation) { this.error = this.label('account_storage_error'); } }
    finally { if (generation === this.generation) { this.busy = false; } }
    const notificationAccount = AppStorage.get<string>('mailNotificationAccountId');
    if (notificationAccount && !this.accounts.some(account => account.id === notificationAccount)) {
      AppStorage.setOrCreate('mailNotificationAccountId', '');
    }
    if (generation === this.generation && this.openInboxOnLaunch && this.accounts.length > 0 &&
      !AppStorage.get<string>('mailNotificationAccountId')) {
      await this.openAccount(this.accounts.find(account => account.id === lastAccount?.id) ?? this.accounts[0], true);
    }
    if (this.active && this.ready) { await this.sendChanged(); }
    if (this.active && this.ready) {
      this.openNotification();
      this.refreshUnreadStatus(true);
      MailNotificationService.settingsChanged(this.getUIContext().getHostContext() as common.Context).catch(() => {});
    }
  }

  private async openNotification(): Promise<void> {
    if (!this.active || !this.openInboxOnLaunch || this.openingNotification ||
      !MailInboxUpdates.isForeground() || !this.ready || this.busy) { return; }
    const accountId = AppStorage.get<string>('mailNotificationAccountId') || '';
    if (!accountId) { return; }
    // A notification cannot discard a draft. The pending tap is handled after
    // the user closes the composer, using its normal save/discard flow.
    if (this.paths.getAllPathName().includes('compose')) { return; }
    const account = this.accounts.find(value => value.id === accountId);
    AppStorage.setOrCreate('mailNotificationAccountId', '');
    if (!account) { return; }
    this.openingNotification = true;
    try {
      // Commit the tap before awaiting optional notification cleanup. A slow
      // settings read must not navigate later over a newer account selection,
      // or consume a tap that the composer then prevents from opening.
      const opening = this.openAccount(account, true, true);
      this.accountStore.notificationSettings(accountId).then(async settings => {
        if (settings.notificationId > 0) { await NotificationPlatform.cancel(settings.notificationId); }
      }).catch(() => {});
      await opening;
    } catch (_) {
      // The account page owns load errors; cleanup cannot replace its state.
    } finally { this.openingNotification = false; }
    if (AppStorage.get<string>('mailNotificationAccountId')) { this.openNotification(); }
  }

  private showError(error: Object): void {
    const code = (error as JmapError).code;
    this.error = code === 'authenticationRequired' ? this.label('account_auth_error') :
      code === 'unsafeEndpoint' || code === 'untrustedApiOrigin' ? this.label('account_endpoint_error') :
      code === 'queryChanged' ? this.label('mailbox_changed') : this.label('account_network_error');
  }

  private unreadChanged(): void {
    this.unreadRevision;
    if (!this.active || !this.ready) { return; }
    this.unreadRefresh = Promise.all([this.unreadRefresh, MailBadgeService.refresh(this.accountStore)])
      .then(() => {}).catch(() => {});
  }

  private refreshUnreadStatus(syncBadge: boolean = false): void {
    if (!this.active || !this.ready) { return; }
    // Numeric totals can change while a Boolean unread dot stays visible.
    // Retain all outstanding local reads until account-store teardown.
    this.unreadRefresh = Promise.all([this.unreadRefresh, MailUnreadStatus.refresh(this.accountStore),
      MailBadgeService.refresh(this.accountStore)]).then(() => {}).catch(() => {});
  }

  private accountHasUnread(accountId: string): boolean {
    this.unreadRevision;
    return MailUnreadStatus.hasUnread(accountId);
  }

  private mailboxHasUnread(mailboxId: string): boolean {
    this.unreadRevision;
    return MailUnreadStatus.hasUnread(this.account.id, mailboxId);
  }

  private async saveCache(operation: Promise<void>, expectedGeneration?: number): Promise<void> {
    const generation = expectedGeneration ?? this.generation;
    try { await operation; }
    catch (_) { if (generation === this.generation) { this.cacheWarning = true; } }
  }

  private showSavedCopy(timestamp: number, fromDirty: boolean = false): void {
    this.savedCopyAt = timestamp; this.savedCopyFromDirty = fromDirty;
    // The saved-copy caption explains the fallback without obscuring the mail.
    // Keep authentication and endpoint errors visible because they need action.
    if (this.error === this.label('account_network_error')) { this.error = ''; }
  }

  private async probe(): Promise<void> {
    if (this.busy) { return; }
    if (this.protocol === 'imap' && !validateEmailAddress(this.emailAddress.trim())) {
      this.error = this.label('imap_email_invalid'); return;
    }
    const generation = ++this.generation;
    this.busy = true; this.error = ''; this.candidates = [];
    try {
      const client = this.clientFactory.create(this.endpoint(), new TokenCredentials(this.secret(), this.protocol === 'imap' ? 'Basic' : 'Bearer'));
      const session = await client.connect();
      if (generation !== this.generation) { return; }
      this.candidates = session.accounts;
      if (this.candidates.length === 1) { await this.saveAccount(this.candidates[0]); }
    } catch (error) { if (generation === this.generation) { this.showError(error); } }
    finally { if (generation === this.generation) { this.busy = false; } }
  }

  private async signIn(provider: MailOAuthProvider): Promise<void> {
    if (this.busy) { return; }
    if (provider === 'google' && !RegisteredMailOAuth.googleBrowserSignInEnabled) {
      this.error = this.label('gmail_app_password_help'); return;
    }
    const email = this.emailAddress.trim();
    if (!validateEmailAddress(email)) { this.error = this.label('imap_email_invalid'); return; }
    const username = this.username.trim() || email;
    const generation = ++this.generation;
    this.busy = true; this.oauthPending = true; this.error = ''; this.token = '';
    const flow = LoopbackBrowserSignIn.forContext(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.oauthFlow = flow;
    let saved: SavedAccount | null = null;
    let stage = 'oauth';
    try {
      const tokens = await flow.signIn(provider, RegisteredMailOAuth.clientID(provider), email, provider === 'microsoft');
      if (generation !== this.generation || !flow.registration) { return; }
      const endpoint = RegisteredMailOAuth.incoming(provider);
      const client = this.clientFactory.create(endpoint, new TokenCredentials(tokens.accessToken, 'Bearer', username));
      stage = 'mail';
      const session = await client.connect();
      if (generation !== this.generation) { return; }
      if (session.accounts.length !== 1) { throw new JmapError('invalidResponse'); }
      const login: SavedOAuthLogin = { registration: flow.registration, username: username, tokens: tokens };
      const smtp = new SmtpSettings(); smtp.endpoint = RegisteredMailOAuth.outgoing(provider); smtp.username = username;
      stage = 'storage';
      saved = await this.accountStore.add(endpoint, session.accounts[0], '', email, smtp, login);
      if (generation !== this.generation) { await this.accountStore.remove(saved.id); saved = null; return; }
      this.emailAddress = ''; this.username = ''; this.candidates = []; this.clearDiscovery();
      this.accounts = await this.accountStore.list();
    } catch (error) {
      if (generation === this.generation) {
        const code = (error as JmapError).code;
        this.error = code === 'cancelled' ? '' :
          `${this.label(oauthFailureLabel(stage === 'oauth' ? flow.failureStage : stage))} (${oauthFailureCode(code)})`;
      }
    } finally {
      if (this.oauthFlow === flow) { this.oauthFlow = undefined; this.oauthPending = false; }
      if (generation === this.generation) { this.busy = false; }
    }
    if (saved && generation === this.generation && this.openInboxOnLaunch) { await this.openAccount(saved, true); }
  }

  private cancelSignIn(): void { this.oauthFlow?.cancel(); ++this.generation; this.busy = false; this.oauthPending = false; }

  private reconnectProvider(account: SavedAccount): MailOAuthProvider | null {
    if (account.authentication !== 'oauth') { return null; }
    if (account.sessionUrl === RegisteredMailOAuth.incoming('google')) {
      return RegisteredMailOAuth.googleBrowserSignInEnabled ? 'google' : null;
    }
    if (account.sessionUrl === RegisteredMailOAuth.incoming('microsoft')) { return 'microsoft'; }
    return null;
  }

  private async reconnectOAuth(account: SavedAccount): Promise<void> {
    const provider = this.reconnectProvider(account);
    if (this.busy || !provider || this.paths.getAllPathName().includes('compose')) { return; }
    const generation = ++this.generation;
    this.busy = true; this.oauthPending = true; this.error = '';
    const flow = LoopbackBrowserSignIn.forContext(this.getUIContext().getHostContext() as common.UIAbilityContext);
    this.oauthFlow = flow;
    let stage = 'oauth', connected = false;
    try {
      const tokens = await flow.signIn(provider, RegisteredMailOAuth.clientID(provider), account.username, provider === 'microsoft');
      if (generation !== this.generation || !flow.registration) { return; }
      // Authenticate as the saved login. A different browser account cannot
      // replace its credentials or gain access to its downloaded cache.
      const client = this.clientFactory.create(account.sessionUrl, new TokenCredentials(tokens.accessToken, 'Bearer', account.username));
      stage = 'mail';
      const session = await client.connect();
      if (generation !== this.generation) { return; }
      const server = session.accounts.find(value => value.id === account.serverId);
      if (!server) { throw new JmapError('authenticationRequired'); }
      stage = 'storage';
      await this.accountStore.replaceOAuth(account, server, { registration: flow.registration, username: account.username, tokens: tokens });
      connected = true;
      MailNotificationService.credentialsChanged(account.id);
      MailNotificationService.settingsChanged(this.getUIContext().getHostContext() as common.Context).catch(() => {});
      if (generation === this.generation && this.account.id === account.id) {
        this.client = this.clientFactory.create(account.sessionUrl, this.accountStore.credentials(account));
      }
    } catch (error) {
      if (generation === this.generation) {
        const code = (error as JmapError).code;
        this.error = code === 'cancelled' ? '' :
          `${this.label(oauthFailureLabel(stage === 'oauth' ? flow.failureStage : stage))} (${oauthFailureCode(code)})`;
      }
    } finally {
      if (this.oauthFlow === flow) { this.oauthFlow = undefined; this.oauthPending = false; }
      if (generation === this.generation) { this.busy = false; }
    }
    if (!connected || generation !== this.generation || this.account.id !== account.id) { return; }
    if (this.paths.getAllPathName().includes('read') && this.selectedId) { await this.loadPage(true); }
    else if (this.mailboxId !== '') { await this.refreshMailbox(); }
    else { await this.loadBoxes(false); }
  }

  private clearDiscovery(): void {
    this.discovered = null; this.smtpEndpoint = ''; this.smtpUsername = '';
    this.incomingChoice = 0; this.outgoingChoice = 0; this.smtpSamePassword = true;
  }

  private async findSettings(): Promise<void> {
    if (this.busy) { return; }
    if (!validateEmailAddress(this.emailAddress.trim())) { this.error = this.label('imap_email_invalid'); return; }
    const generation = ++this.generation;
    this.busy = true; this.error = ''; this.clearDiscovery(); this.candidates = [];
    try {
      const result = await this.discoveryService.discover(this.emailAddress.trim());
      if (generation === this.generation) { this.discovered = result; }
    } catch (error) {
      if (generation === this.generation) {
        this.error = this.label((error as DiscoveryError).code === 'invalidAddress' ? 'imap_email_invalid' : 'discovery_not_found');
      }
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  private serverChoiceLabel(server: DiscoveredServer): string {
    return `${server.protocolName.toUpperCase()} · ${server.hostname}:${server.port} · ${server.security}`;
  }

  private discoveryReason(server: DiscoveredServer): string {
    return this.label(server.reason === 'unsupportedAuthentication' ? 'discovery_auth_unavailable' :
      server.reason === 'imapStarttlsPending' ? 'discovery_starttls_unavailable' : 'discovery_server_unavailable');
  }

  private applyDiscovered(): void {
    const config = this.discovered;
    const incoming = config?.incoming[this.incomingChoice];
    if (!incoming || !incoming.supported || incoming.protocolName !== 'imap') { return; }
    this.serverUrl = incoming.hostname; this.port = incoming.port.toString(); this.username = incoming.username;
    const outgoing = config?.outgoing[this.outgoingChoice];
    this.smtpEndpoint = outgoing?.supported ? `${outgoing.security === 'SSL' ? 'smtps' : 'smtp'}://${outgoing.hostname}:${outgoing.port}` : '';
    this.smtpUsername = outgoing?.supported ? outgoing.username : '';
    this.candidates = []; this.error = ''; this.discovered = null;
  }

  private discoveredSmtp(): SmtpSettings | undefined {
    if (this.protocol !== 'imap' || this.smtpEndpoint === '') { return undefined; }
    const settings = new SmtpSettings();
    settings.endpoint = this.smtpEndpoint; settings.username = this.smtpUsername.trim();
    settings.password = this.smtpSamePassword ? this.token : '';
    return settings;
  }

  private async saveAccount(server: JmapAccount): Promise<void> {
    if (!this.active) { return; }
    const generation = ++this.generation, store = this.accountStore;
    const current = (): boolean => this.active && generation === this.generation;
    this.busy = true; this.error = '';
    try {
      const saved = await store.add(this.endpoint(), server, this.secret(), this.protocol === 'imap' ? this.emailAddress.trim() : '', this.discoveredSmtp());
      if (!current()) { return; }
      const accounts = await store.list();
      if (!current()) { return; }
      this.token = ''; this.username = ''; this.emailAddress = ''; this.candidates = []; this.serverUrl = '';
      this.clearDiscovery();
      this.accounts = accounts;
      this.busy = false;
      if (this.openInboxOnLaunch) { await this.openAccount(saved, true); }
    } catch (_) {
      if (current()) { this.token = ''; this.candidates = []; this.error = this.label('account_storage_error'); }
    } finally { if (current()) { this.busy = false; } }
  }

  private endpoint(): string {
    if (this.protocol === 'jmap') { return this.serverUrl.trim(); }
    const port = Number(this.port);
    if (!Number.isInteger(port) || port < 1 || port > 65535) { throw new JmapError('unsafeEndpoint'); }
    const host = this.serverUrl.trim();
    return `imaps://${host}:${port}`;
  }

  private secret(): string {
    if (this.protocol === 'jmap') { return this.token.trim(); }
    const username = this.username.trim();
    if (!username || username.includes(':')) { throw new JmapError('authenticationRequired'); }
    const bytes = new util.TextEncoder().encodeInto(`${username}:${this.token}`);
    try { return new util.Base64Helper().encodeToStringSync(bytes); }
    finally { bytes.fill(0); }
  }

  private async removeAccount(account: SavedAccount): Promise<void> {
    if (!this.active || this.busy) { return; }
    const generation = ++this.generation, store = this.accountStore, accountId = account.id;
    const remaining = this.accounts.filter(value => value.id !== accountId);
    const context = this.getUIContext().getHostContext() as common.Context;
    const current = (): boolean => this.active && generation === this.generation;
    this.busy = true; this.error = '';
    try {
      const notifications = await store.notificationSettings(accountId);
      this.messageLoader?.cancel(); AutomaticMailWork.cancelInactive();
      await store.remove(accountId);
      // The requested removal and its original notification cleanup survive
      // navigation; only the originating view may apply the resulting state.
      NotificationPlatform.cancel(notifications.notificationId).catch(() => {});
      MailNotificationService.settingsChanged(context).catch(() => {});
      if (!current()) { return; }
      const accounts = await store.list().catch(() => remaining);
      if (!current()) { return; }
      this.accounts = accounts;
      this.refreshUnreadStatus();
      if (this.account.id === accountId) {
        if (accounts.length > 0) { await this.openAccount(accounts[0], true); }
        else {
          this.client = null; this.account = new SavedAccount(); this.paths.clear(false);
          this.selected = null; this.selectedId = ''; this.bodyLoaded = false; this.readerDocument = null; this.readerScrollActive = false;
          this.boxes = []; this.emails = []; this.mailboxId = ''; this.boxName = '';
          this.conversation = []; this.conversationIndex = []; this.conversationById.clear(); this.conversationRevision++;
          this.readOnly = true; this.refreshRequired = false; this.savedCopyAt = 0;
          MailNotificationService.setVisibleAccount('');
        }
      }
    }
    catch (_) { if (current()) { this.error = this.label('account_storage_error'); } }
    finally { if (current()) { this.busy = false; } }
  }

  private async openAccount(account: SavedAccount, openInbox: boolean = false, refreshInbox: boolean = false): Promise<void> {
    this.messageLoader?.cancel(); AutomaticMailWork.cancelInactive();
    if (this.paths.getAllPathName().includes('compose')) { return; }
    this.pendingSwipeAction?.();
    ++this.generation; ++this.mailboxRefreshRevision; this.busy = false; this.mailboxRefreshActive = false; this.refreshing = false; this.boxRolesCurrent = false;
    this.resetInboxScroll();
    this.token = ''; this.candidates = []; this.account = account;
    if (this.inboxTimer !== -1) { clearTimeout(this.inboxTimer); this.inboxTimer = -1; }
    if (this.inboxAnchorTimer !== -1) { clearTimeout(this.inboxAnchorTimer); this.inboxAnchorTimer = -1; }
    ++this.inboxLoadRevision; this.inboxSwipes.clear(); this.inboxScrollActive = false;
    MailNotificationService.setVisibleAccount(account.id);
    this.selected = null; this.selectedId = ''; this.bodyLoaded = false; this.readerDocument = null; this.readerScrollActive = false; this.readerDetails = false;
    this.attachmentBusy = ''; this.attachmentError = '';
    this.query = ''; this.unreadOnly = false;
    this.readOnly = true; this.refreshRequired = false;
    this.savedCopyAt = 0; this.cacheWarning = false;
    this.archiveUndo = null; this.moveNotice = '';
    this.client = this.clientFactory.create(account.sessionUrl, this.accountStore.credentials(account));
    this.boxes = []; this.emails = []; this.conversationIndex = []; this.conversationIndexPending = false; this.conversation = []; this.conversationById.clear(); this.conversationRevision++; this.mailboxId = ''; this.boxName = '';
    this.boxesDirty = false; this.emailsDirty = false;
    this.nextPosition = null; this.queryState = undefined;
    // A selected offline account is still the last account the user visited.
    const remembered = this.accountStore.rememberVisitedAccount(account.id).then(() => true, () => false);
    if (this.openInboxOnLaunch) { this.paths.clear(false); }
    else { this.paths.pushPathByName('boxes', null); }
    const loading = this.loadBoxes();
    let generation = this.generation;
    await loading;
    if (!this.active || generation !== this.generation || this.account.id !== account.id) { return; }
    if ((openInbox || this.openInboxOnLaunch) && !this.busy &&
        this.paths.getAllPathName().length === (this.openInboxOnLaunch ? 0 : 1)) {
      const inbox = this.boxes.find(box => box.role === 'inbox');
      if (inbox) {
        const opening = this.openBox(inbox, !refreshInbox); generation = this.generation;
        await opening;
      }
    }
    const didRemember = await remembered;
    if (!this.active || generation !== this.generation || this.account.id !== account.id) { return; }
    if (!didRemember && this.error === '') {
      this.error = this.label('account_selection_error');
    }
    if (this.account.id === account.id && this.client && !this.boxRolesCurrent && account.sessionUrl.startsWith('imaps:')) {
      this.upgradeSentFolder(this.client, account);
    }
  }

  private async upgradeSentFolder(client: JmapService, account: SavedAccount): Promise<void> {
    if (!account.sessionUrl.startsWith('imaps:') || this.sentFolderUpdates.has(account.id)) { return; }
    this.sentFolderUpdates.add(account.id);
    try {
      // One mailbox-role metadata upgrade runs behind the cached inbox. No
      // message bodies are fetched and no submitted message is sent again.
      const boxes = await client.mailboxes(account.serverId);
      const cached = await this.accountStore.mail.boxes(account.id);
      await this.accountStore.mail.saveBoxes(account.id, boxes, cached?.readOnly);
      const updated = await this.accountStore.mail.boxes(account.id);
      if (!this.active || this.account.id !== account.id || !updated) { return; }
      const generation = this.generation;
      this.boxRolesCurrent = true;
      await this.applyBoxes(updated.boxes, account.id, generation);
      await this.loadConversationIndex(account.id, generation);
    } catch (_) { /* Keep downloaded copies available until a later explicit refresh. */ }
  }

  private async applyBoxes(boxes: JmapMailbox[], accountId: string, generation: number): Promise<void> {
    if (!this.active || this.account.id !== accountId || generation !== this.generation) { return; }
    this.boxes = boxes;
    const sent = serverSentMailbox(boxes);
    if (this.mailboxId !== LOCAL_SENT_MAILBOX || !sent) { return; }
    const view = await this.accountStore.mail.view(accountId, sent.id, true, false);
    if (!this.active || this.account.id !== accountId || generation !== this.generation ||
      this.mailboxId !== LOCAL_SENT_MAILBOX) { return; }
    this.mailboxId = sent.id; this.boxName = this.boxLabel(sent);
    this.emails = (view?.emails || []).map(mail => MailOperations.overlay(accountId, mail));
    this.nextPosition = view?.nextPosition ?? null; this.queryState = view?.queryState;
    this.emailsDirty = view?.stateDirty === true;
    this.refreshRequired = this.emailsDirty && MailOperations.count(accountId) === 0;
  }

  private async loadBoxes(preferCache: boolean = true): Promise<void> {
    const client = this.client;
    if (!client || this.busy) { return; }
    const account = this.account;
    const generation = ++this.generation;
    this.busy = true; this.error = '';
    try {
      if (preferCache) {
        const cached = await this.accountStore.mail.boxes(account.id).catch(() => null);
        if (generation !== this.generation) { return; }
        if (cached) {
          this.readOnly = cached.readOnly ?? false;
          await this.applyBoxes(cached.boxes, account.id, generation);
          if (generation !== this.generation) { return; }
          this.boxRolesCurrent = cached.roleRevision === MAILBOX_ROLE_REVISION;
          this.boxesDirty = false; this.savedCopyAt = 0;
          return;
        }
      }
      const session = await client.connect();
      if (generation !== this.generation) { return; }
      const boxes = await client.mailboxes(account.serverId);
      const readOnly = session.accounts.find((value) => value.id === account.serverId)?.isReadOnly !== false;
      await this.saveCache(this.accountStore.mail.saveBoxes(account.id, boxes, readOnly), generation);
      const stored = await this.accountStore.mail.boxes(account.id).catch(() => null);
      if (generation === this.generation) {
        this.readOnly = readOnly;
        this.boxRolesCurrent = true;
        await this.applyBoxes((stored?.boxes || boxes).sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name)), account.id, generation);
        if (generation !== this.generation) { return; }
        this.boxesDirty = false;
        this.savedCopyAt = 0;
      }
    } catch (error) {
      if (generation === this.generation) {
        this.showError(error);
        try {
          const cached = await this.accountStore.mail.boxes(account.id);
          if (cached && generation === this.generation) {
            await this.applyBoxes(cached.boxes, account.id, generation);
            if (generation === this.generation) { this.showSavedCopy(cached.savedAt); }
          }
        } catch (_) { if (generation === this.generation) { this.error = this.label('cache_read_error'); } }
      }
    }
    finally {
      if (generation === this.generation) { this.busy = false; }
      this.refreshUnreadStatus();
    }
  }

  private async openBox(box: JmapMailbox, preferCache: boolean = true): Promise<void> {
    this.messageLoader?.cancel(); AutomaticMailWork.cancelInactive();
    this.pendingSwipeAction?.();
    ++this.generation; ++this.mailboxRefreshRevision; this.busy = false; this.mailboxRefreshActive = false; this.refreshing = false;
    if (this.inboxTimer !== -1) { clearTimeout(this.inboxTimer); this.inboxTimer = -1; }
    if (this.inboxAnchorTimer !== -1) { clearTimeout(this.inboxAnchorTimer); this.inboxAnchorTimer = -1; }
    ++this.inboxLoadRevision; this.inboxSwipes.clear(); this.inboxScrollActive = false;
    this.savedCopyAt = 0;
    this.archiveUndo = null; this.moveNotice = '';
    this.query = ''; this.unreadOnly = false; this.resetInboxScroll();
    this.mailboxId = box.id; this.boxName = this.boxLabel(box); this.emails = [];
    this.queryState = undefined; this.nextPosition = null;
    if (this.openInboxOnLaunch) { this.paths.clear(false); }
    else { this.paths.pushPathByName('emails', null); }
    await this.loadPage(true, preferCache);
  }

  private inboxBlocked(): boolean {
    return this.busy || this.mailboxRefreshActive || this.refreshing || this.changing || this.swipeClosing || this.inboxSwipes.size > 0 || this.inboxScrollActive || this.inboxPullActive ||
      this.paths.getAllPathName().includes('compose');
  }

  private retireInboxInteraction(): void {
    const closeSwipes = this.inboxSwipes.size > 0 || this.swipeClosing;
    // A hidden List/Refresh may never deliver its final offset/scroll callback.
    // Finish only an already accepted action; closing other panels submits none.
    this.pendingSwipeAction?.();
    this.inboxScrollActive = false; this.inboxPullActive = false; this.inboxSwipes.clear();
    if (closeSwipes) {
      try { this.mailScroller.closeAllSwipeActions(); } catch (_) { /* The retired List may be detached. */ }
    }
  }

  private inboxVisibilityChanged(visible: boolean): void {
    this.inboxVisible = visible;
    if (!visible) { this.retireInboxInteraction(); }
    this.inboxChanged();
  }

  private readerVisibilityChanged(visible: boolean): void {
    this.readerVisible = visible;
    if (!visible) { this.readerScrollActive = false; this.messageLoader?.cancel(); }
    this.inboxChanged();
  }

  private inboxChanged(): void {
    if (!MailInboxUpdates.isForeground()) { DeferredSave.flushAll().catch(() => {}); }
    const foreground = MailInboxUpdates.isForeground();
    if (!foreground && this.unreadForeground === true) {
      this.retireInboxInteraction(); this.readerScrollActive = false; this.messageLoader?.cancel();
    }
    AutomaticMailWork.cancelInactive();
    if (foreground !== this.unreadForeground) {
      this.unreadForeground = foreground;
      if (foreground) { this.refreshUnreadStatus(true); }
    }
    this.inboxUpdateRevision;
    if (!MailInboxUpdates.isForeground()) {
      if (this.inboxTimer !== -1) { clearTimeout(this.inboxTimer); this.inboxTimer = -1; }
      return;
    }
    // Busy completion and foreground changes already reach this callback.
    // Retained notification taps need no polling timer while work is pending.
    this.openNotification();
    if (this.conversationIndexPending && this.active && this.ready && !this.inboxBlocked()) {
      this.loadConversationIndex(this.account.id, this.generation).catch(() => {});
    }
    if (!this.active || !this.ready || !this.client || !this.account.id ||
      !this.boxes.some(box => box.id === this.mailboxId && box.role === 'inbox') || this.inboxBlocked() || this.readerScrollActive) { return; }
    const key = `${this.account.id}:${this.mailboxId}`, revision = MailInboxUpdates.revision(this.account.id);
    if ((!this.inboxCachedUpdates.has(key) && revision <= (this.inboxAcknowledged.get(key) || 0)) || this.inboxRequests.has(key)) { return; }
    const retryKey = `${key}:${revision}`;
    if (this.inboxRetryKey !== retryKey) { this.inboxRetryKey = retryKey; this.inboxRetries = 0; this.inboxRetryAt = 0; }
    if (this.inboxRetries >= 3 || this.inboxTimer !== -1) { return; }
    this.inboxTimer = setTimeout(() => {
      this.inboxTimer = -1;
      if (!MailInboxUpdates.isForeground() || this.inboxBlocked() || this.readerScrollActive || !this.active ||
        key !== `${this.account.id}:${this.mailboxId}` || this.inboxRequests.has(key)) { return; }
      const account = this.account, client = this.client;
      if (!client) { return; }
      const requested = MailInboxUpdates.revision(account.id);
      const work = this.refreshInboxQuiet(client, account, this.mailboxId, requested, this.inboxLoadRevision);
      this.inboxRequests.set(key, work);
      work.finally(() => {
        if (this.inboxRequests.get(key) === work) { this.inboxRequests.delete(key); }
        this.inboxChanged();
      });
    }, Math.max(250, this.inboxRetryAt - Date.now()));
  }

  private async refreshInboxQuiet(client: JmapService, account: SavedAccount, mailboxId: string,
    requested: number, loadRevision: number): Promise<boolean> {
    const key = `${account.id}:${mailboxId}`;
    const current = (): boolean => this.active && this.account.id === account.id && this.mailboxId === mailboxId &&
      this.inboxLoadRevision === loadRevision;
    let downloaded = false;
    try {
      if (!this.inboxCachedUpdates.has(key)) {
        this.inboxFetching.add(key);
        const mutationRevision = MailCache.mutationRevision();
        const cached = await this.accountStore.mail.view(account.id, mailboxId, true, false);
        if (!current() || !MailInboxUpdates.isForeground()) { return false; }
        const previewKnownIds = (cached?.emails || []).filter(mail => mail.preview.trim().length > 0).slice(0, 500).map(mail => mail.id);
        const page = await AutomaticMailWork.run(() => client.emailPage(account.serverId, mailboxId, 0, undefined, previewKnownIds),
          () => current() && MailInboxUpdates.isForeground() && !this.inboxBlocked() && !this.readerScrollActive);
        if (!current()) { return false; }
        const known = new Set((cached?.emails || []).map(mail => mail.id));
        const firstKnown = page.emails.findIndex(mail => known.has(mail.id));
        // Only a prepended unread member is an arrival. Older unknown rows
        // exposed after deletions, or a whole new UID epoch, stay silent.
        const arrivals = cached?.emails.length === 0 ? page.emails : firstKnown > 0 ? page.emails.slice(0, firstKnown) : [];
        const newUnread = cached !== null && arrivals.some(mail => !known.has(mail.id) &&
          !MailOperations.overlay(account.id, mail).keywords.includes('$seen'));
        const ids = new Set(page.emails.map(mail => mail.id));
        const previous = cached?.emails || this.emails;
        const tail = page.nextPosition === null || !previous.some(mail => ids.has(mail.id)) ? [] :
          previous.filter(mail => !ids.has(mail.id));
        const messages = page.emails.concat(tail);
        // Keep the downloaded tail but restart paging from the verified server
        // head. Subsequent Load more skips duplicate-only pages without gaps.
        await this.accountStore.mail.saveView(account.id, mailboxId, messages, page.nextPosition, page.queryState, mutationRevision);
        if (!current()) { return false; }
        downloaded = true;
        this.inboxAcknowledged.set(key, requested); this.inboxCachedUpdates.add(key);
        this.refreshUnreadStatus();
        if (newUnread) {
          // Inbox updates remain independent of alerts, but an account's
          // opt-out applies to its in-app banner as well as OS notifications.
          const settings = await this.accountStore.notificationSettings(account.id).catch(() => null);
          if (current() && settings?.enabled === true) { MailBannerNotice.showInboxArrival(account.id, requested); }
        }
      }
      const operationRevision = this.operationRevision;
      const cached = await this.accountStore.mail.view(account.id, mailboxId, true, false);
      if (!current()) { return downloaded; }
      // A missing/expired view is not a successful deferred application. Use
      // the bounded retry path instead of scheduling cache reads every 250 ms.
      if (!cached) { throw new Error('Inbox cache unavailable'); }
      if (this.inboxBlocked() || !MailInboxUpdates.isForeground() || operationRevision !== this.operationRevision) { return downloaded; }
      const before = this.visibleEmails(), anchor = before[this.inboxFirstVisible];
      const scrollRevision = this.inboxScrollRevision;
      let anchorY: number | null = null;
      try {
        if (anchor && this.mailScroller.currentOffset().yOffset > 0.5) { anchorY = this.mailScroller.getItemRect(this.inboxFirstVisible).y; }
      } catch (_) {}
      ++this.inboxViewRevision;
      this.emails = cached.emails.map(mail => MailOperations.overlay(account.id, mail));
      this.nextPosition = cached.nextPosition ?? null; this.queryState = cached.queryState;
      this.emailsDirty = cached.stateDirty === true;
      if (!this.paths.getAllPathName().includes('read')) {
        this.refreshRequired = this.emailsDirty && MailOperations.count(account.id) === 0;
        this.savedCopyAt = 0; this.savedCopyFromDirty = false;
      }
      this.inboxCachedUpdates.delete(key); this.inboxRetries = 0; this.inboxRetryAt = 0;
      await this.loadConversationIndex(account.id, this.generation, operationRevision);
      if (anchor && anchorY !== null && current() && this.inboxScrollRevision === scrollRevision) {
        const offset = anchorY;
        if (this.inboxAnchorTimer !== -1) { clearTimeout(this.inboxAnchorTimer); }
        this.inboxAnchorTimer = setTimeout(() => {
          this.inboxAnchorTimer = -1;
          if (!current() || this.inboxScrollRevision !== scrollRevision || this.inboxScrollActive) { return; }
          const index = this.visibleEmails().findIndex(mail => mail.id === anchor.id);
          if (index >= 0) {
            const options: ScrollToIndexOptions = { extraOffset: LengthMetrics.vp(-offset) };
            try { this.mailScroller.scrollToIndex(index, false, ScrollAlign.START, options); } catch (_) {}
          }
        }, 16);
      }
      return downloaded;
    } catch (error) {
      if (current() && !(error instanceof AutomaticMailWorkCancelled)) { ++this.inboxRetries; this.inboxRetryAt = Date.now() + 10000; }
      return false;
    } finally { this.inboxFetching.delete(key); }
  }

  private async loadPage(refresh: boolean, preferCache: boolean = false): Promise<void> {
    const client = this.client;
    if (!client || this.busy || (!refresh && this.nextPosition === null)) { return; }
    const account = this.account, mailboxId = this.mailboxId;
    const inboxKey = `${account.id}:${mailboxId}`, pending = this.inboxRequests.get(inboxKey);
    if (!preferCache && pending) {
      const waitingGeneration = this.generation;
      const network = this.inboxFetching.has(inboxKey), satisfied = await pending;
      if (this.account.id !== account.id || this.mailboxId !== mailboxId || !this.active || this.busy ||
        this.generation !== waitingGeneration || (!refresh && this.nextPosition === null)) { return; }
      if (refresh && network && satisfied) { return; }
    }
    ++this.inboxLoadRevision;
    const requested = MailInboxUpdates.revision(account.id);
    const generation = ++this.generation;
    this.busy = true; this.error = '';
    let refreshRelated = false;
    try {
      if (preferCache || mailboxId.startsWith('local_')) {
        const cached = await this.accountStore.mail.view(account.id, mailboxId, true, false).catch(() => null);
        if (generation !== this.generation) { return; }
        if (cached) {
          this.emails = cached.emails; this.nextPosition = cached.nextPosition ?? null;
          this.queryState = cached.queryState; this.emailsDirty = cached.stateDirty === true;
          this.refreshRequired = cached.stateDirty === true;
          if (cached.stateDirty) { this.showSavedCopy(cached.savedAt, true); }
          else { this.savedCopyAt = 0; }
          return;
        }
        if (mailboxId.startsWith('local_')) { return; }
      }
      const revision = MailCache.mutationRevision();
      const previous = refresh ? [] : this.emails;
      const previousIds = new Set(previous.map(mail => mail.id));
      const previewCache = await this.accountStore.mail.view(account.id, mailboxId, true, false).catch(() => null);
      if (!this.active || !MailInboxUpdates.isForeground() || generation !== this.generation || this.account.id !== account.id || this.mailboxId !== mailboxId) { return; }
      const previewKnownIds = (previewCache?.emails || previous).filter(mail => mail.preview.trim().length > 0).slice(0, 500).map(mail => mail.id);
      let page = await client.emailPage(account.serverId, mailboxId,
        refresh ? 0 : this.nextPosition as number, refresh ? undefined : this.queryState, previewKnownIds);
      // A quiet prepend preserves the old downloaded tail. Walk any pages that
      // consist entirely of that tail instead of advancing past unseen rows.
      let skippedPages = 0;
      while (!refresh && page.nextPosition !== null && page.emails.every(mail => previousIds.has(mail.id)) && skippedPages < 20) {
        if (generation !== this.generation || !MailInboxUpdates.isForeground()) { return; }
        page = await client.emailPage(account.serverId, mailboxId, page.nextPosition, page.queryState, previewKnownIds); ++skippedPages;
      }
      if (!this.active || generation !== this.generation || this.account.id !== account.id || this.mailboxId !== mailboxId) { return; }
      let messages = previous.concat(page.emails.filter(mail => !previousIds.has(mail.id)));
      let stateDirty = false;
      try {
        await this.accountStore.mail.saveView(account.id, mailboxId, messages, page.nextPosition, page.queryState, revision);
        const persisted = await this.accountStore.mail.view(account.id, mailboxId, true, false);
        if (persisted) { messages = persisted.emails; stateDirty = persisted.stateDirty === true; }
      } catch (_) { if (generation === this.generation) { this.cacheWarning = true; } }
      if (generation === this.generation) {
        ++this.inboxViewRevision;
        this.emails = messages.map(mail => MailOperations.overlay(account.id, mail));
        this.nextPosition = page.nextPosition; this.queryState = page.queryState;
        this.emailsDirty = false; this.refreshRequired = stateDirty && MailOperations.count(account.id) === 0;
        this.savedCopyAt = 0;
        if (refresh) { this.inboxAcknowledged.set(inboxKey, requested); this.inboxCachedUpdates.delete(inboxKey); }
        refreshRelated = refresh;
      }
    } catch (error) {
      if (generation === this.generation) {
        this.showError(error);
        try {
          const cached = await this.accountStore.mail.view(account.id, mailboxId, true, false);
          if (cached && generation === this.generation) {
            this.emails = cached.emails; this.showSavedCopy(cached.savedAt);
            this.nextPosition = cached.nextPosition ?? null; this.queryState = cached.queryState;
            this.refreshRequired = cached.stateDirty === true;
          }
        } catch (_) { if (generation === this.generation) { this.error = this.label('cache_read_error'); } }
      }
    }
    finally {
      if (generation === this.generation) { this.busy = false; }
      this.inboxChanged();
      this.refreshUnreadStatus();
      // Inbox completion owns only its downloaded headers and durable cache.
      // The account-wide index and optional companion folder must not keep
      // pull feedback waiting on another network session or local scan.
      this.loadConversationIndex(account.id, generation).then(async () => {
        if (refreshRelated) { await this.refreshConversationFolder(client, account, mailboxId, generation); }
      }).catch(() => {});
    }
  }

  private async read(mail: JmapEmail, inConversation: boolean = false): Promise<void> {
    const readerOpen = this.paths.getAllPathName().includes('read');
    if (readerOpen && this.selectedId === mail.id && (this.bodyLoaded || this.busy)) { return; }
    const account = this.account, client = this.client, loader = this.messageLoader;
    const readerOperationRevision = this.operationRevision;
    if (!client || !loader) { return; }
    loader.cancel();
    const generation = ++this.generation;
    const current = (): boolean => this.active && generation === this.generation && this.account.id === account.id &&
      MailInboxUpdates.isForeground();
    ++this.mailboxRefreshRevision; this.mailboxRefreshActive = false; this.refreshing = false;
    this.selected = mail; this.bodyLoaded = false; this.selectedId = mail.id; this.refreshRequired = false;
    this.readerDocument = null; this.readerDetails = false; this.readerScrollActive = false;
    this.attachmentBusy = ''; this.attachmentError = ''; this.savedCopyAt = 0;
    this.busy = true; this.error = ''; AutomaticMailWork.cancelInactive();
    if (!inConversation && !readerOpen) { this.paths.pushPathByName('read', null); }
    this.conversation = conversationMessages(mail, this.conversationIndex).reverse();
    try {
      // Publish the body before optional pictures or refreshed metadata. The
      // reader fills its image responses without replacing this HTML document.
      const result = await loader.open(client, account, mail, this.label('show_quoted_text'), this.label('hide_quoted_text'), current);
      if (!current()) { return; }
      const acknowledged = this.operationRevision !== readerOperationRevision && this.selected?.id === mail.id ? this.selected : null;
      this.selected = MailOperations.overlay(account.id, result.mail);
      this.readerDocument = result.document;
      this.bodyLoaded = true;
      if (acknowledged) { this.applyReaderMetadata(MailOperations.overlay(account.id, acknowledged)); }
      this.conversation = conversationMessages(this.selected, this.conversationIndex).reverse();
      // A slow local metadata queue must not leave an already downloaded body
      // behind the loading spinner. Ignore late results after navigation.
      const metadataRevision = this.operationRevision;
      this.accountStore.mail.emailSummary(account.id, mail.id).then(latest => {
        if (!current() || !this.bodyLoaded || this.selectedId !== mail.id || this.operationRevision !== metadataRevision) { return; }
        if (latest) { this.applyReaderMetadata(MailOperations.overlay(account.id, latest.mail)); }
        this.refreshRequired = latest?.stateDirty === true && !MailOperations.pending(account.id, mail.id);
      }).catch(() => {});
    } catch (error) {
      if (current() && !(error instanceof MailMessageLoadCancelled)) { this.showError(error as Object); }
    } finally {
      if (generation === this.generation) { this.busy = false; }
    }
    if (current() && this.bodyLoaded && this.selected && !this.selected.keywords.includes('$seen') &&
      !MailOperations.pending(account.id, mail.id) && this.allows('$seen')) { await this.changeKeyword('$seen'); }
  }

  private async loadConversationIndex(accountId: string, generation: number, operationRevision?: number): Promise<void> {
    if (!this.active || generation !== this.generation || accountId !== this.account.id) { return; }
    if (!MailInboxUpdates.isForeground()) { this.conversationIndexPending = true; return; }
    this.conversationIndexPending = false;
    const viewRevision = this.inboxViewRevision, revision = ++this.conversationLoadRevision;
    const operation = operationRevision ?? this.operationRevision;
    try {
      const records = await this.accountStore.mail.cachedMessages(accountId, false);
      if (!this.active || generation !== this.generation || accountId !== this.account.id || viewRevision !== this.inboxViewRevision ||
        revision !== this.conversationLoadRevision || operation !== this.operationRevision) { return; }
      if (!MailInboxUpdates.isForeground()) { this.conversationIndexPending = true; return; }
      this.conversationIndex = records.map(record => MailOperations.overlay(accountId, record.mail));
      this.conversationById.clear();
      const messageGroups = new Map<string, JmapEmail[]>();
      for (const group of conversationGroups(this.conversationIndex.concat(this.emails))) {
        for (const mail of group) {
          this.conversationById.set(mail.id, group);
          for (const id of mail.messageIds) { messageGroups.set(id, group); }
        }
      }
      for (const mail of this.conversationIndex.concat(this.emails)) {
        if (!this.conversationById.has(mail.id)) {
          const id = mail.messageIds.find(value => messageGroups.has(value));
          if (id) { this.conversationById.set(mail.id, messageGroups.get(id)!); }
        }
      }
      // Map mutations are not observed by ArkUI. Publish only after the full
      // index is ready so cached Inbox/Sent rows and counts refresh together.
      this.conversationRevision++;
      if (this.selected) { this.conversation = conversationMessages(this.selected, this.conversationIndex).reverse(); }
    } catch (_) { /* The current folder remains usable if its cache cannot be read. */ }
  }

  // Pair Inbox/Sent header refreshes; bodies remain lazy and cached. Reopening
  // or switching a cached account does not enter this network path.
  private async refreshConversationFolder(client: JmapService, account: SavedAccount, mailboxId: string, generation: number): Promise<void> {
    if (!this.active || !MailInboxUpdates.isForeground() || this.paths.getAllPathName().includes('compose') || generation !== this.generation || account.id !== this.account.id || mailboxId !== this.mailboxId) { return; }
    const current = this.boxes.find(box => box.id === mailboxId);
    if (!current || !['inbox', 'sent'].includes(current.role || '')) { return; }
    const related = this.boxes.find(box => box.role === (current.role === 'inbox' ? 'sent' : 'inbox'));
    if (!related || related.id.startsWith('local_')) { return; }
    const key = `${account.id}:${related.id}`;
    if (this.conversationRefreshes.has(key)) {
      this.conversationRefreshes.set(key, generation); return;
    }
    this.conversationRefreshes.set(key, generation);
    try {
      const revision = MailCache.mutationRevision();
      const cached = await this.accountStore.mail.view(account.id, related.id, true, false).catch(() => null);
      if (!this.active || !MailInboxUpdates.isForeground() || this.paths.getAllPathName().includes('compose') || generation !== this.generation || this.account.id !== account.id || this.mailboxId !== mailboxId) { return; }
      const previewKnownIds = (cached?.emails || []).filter(mail => mail.preview.trim().length > 0).slice(0, 500).map(mail => mail.id);
      const page = await AutomaticMailWork.run(() => client.emailPage(account.serverId, related.id, 0, undefined, previewKnownIds),
        () => this.active && MailInboxUpdates.isForeground() && generation === this.generation &&
          this.account.id === account.id && this.mailboxId === mailboxId && !this.inboxBlocked() && !this.readerScrollActive);
      // A superseded list response must not overwrite a newer Inbox/Sent view.
      // Confirmed message mutations keep their separate original-account path.
      if (!this.active || generation !== this.generation || this.account.id !== account.id || this.mailboxId !== mailboxId) { return; }
      await this.saveCache(this.accountStore.mail.saveView(account.id, related.id, page.emails, page.nextPosition, page.queryState, revision), generation);
      await this.loadConversationIndex(account.id, generation);
    } catch (_) { /* Keep the previous downloaded conversation when offline. */ }
    finally {
      const latest = this.conversationRefreshes.get(key);
      this.conversationRefreshes.delete(key);
      // A later pull still needs its companion update if it superseded this
      // response. Retain only that latest intent, never concurrent requests
      // or an old response that could overwrite a newer direct folder load.
      if (latest !== undefined && latest !== generation) {
        await this.refreshConversationFolder(client, account, mailboxId, latest);
      }
    }
  }

  private allows(keyword: JmapKeyword): boolean {
    return !this.busy && this.savedCopyAt === 0 && !this.refreshRequired && !this.readOnly && this.selected !== null &&
      canSetKeyword(this.selected, this.boxes, keyword);
  }

  private applyMessage(mail: JmapEmail | null): void {
    this.selected = mail; this.bodyLoaded = mail !== null;
    if (mail) { this.conversation = conversationMessages(mail, this.conversationIndex).reverse(); }
    this.emails = mail === null ? this.emails.filter((old) => old.id !== this.selectedId) :
      this.emails.map((old) => old.id === mail.id ? mail : old);
    if (mail === null) { this.error = this.label('message_removed'); }
  }

  private applyReaderMetadata(mail: JmapEmail): void {
    const selected = this.selected;
    if (!selected || (selected.id !== mail.id && MailOperations.currentEmailId(this.account.id, selected.id) !== mail.id)) { return; }
    // A flag acknowledgement owns mutable state, not the open document. Keep
    // the reader's body/header snapshot and let only opening publish a saved view.
    // In particular, an acknowledgement cannot complete an in-flight body read.
    const updated = shallowCopyEmail(selected);
    if (selected.id !== mail.id) {
      updated.id = mail.id; updated.cachedSourceId = selected.cachedSourceId || selected.id;
      updated.cachedAttachmentSourceIds = mail.cachedAttachmentSourceIds;
      if (updated.threadId === selected.id) { updated.threadId = mail.threadId; }
      this.selectedId = mail.id; this.attachmentBusy = ''; this.attachmentError = '';
    }
    updated.keywords = mail.keywords; updated.mailboxIds = mail.mailboxIds;
    updated.maySetSeen = mail.maySetSeen; updated.maySetKeywords = mail.maySetKeywords;
    this.selected = updated;
    this.conversation = this.conversation.map(value => value.id === selected.id ? updated : value);
  }

  private async changeKeyword(keyword: JmapKeyword): Promise<void> {
    const client = this.client, mail = this.selected;
    if (!client || !mail || !this.rowAllows(mail, keyword)) { return; }
    MailOperations.setKeyword(this.accountStore, client, this.account.id, this.account.serverId, mail, keyword);
    this.applyMessage(MailOperations.overlay(this.account.id, mail));
  }

  private async operationsChanged(): Promise<void> {
    this.operationRevision;
    this.refreshUnreadStatus();
    if (!this.active || !this.ready || !this.account.id) { return; }
    const accountId = this.account.id, generation = this.generation, revision = this.operationRevision, viewRevision = this.inboxViewRevision;
    this.archiveUndo = MailOperations.undo(accountId);
    this.moveNotice = this.archiveUndo ? this.label('message_archived') : '';
    this.emails = this.emails.map(mail => MailOperations.overlay(accountId, mail));
    if (this.selected) { this.applyReaderMetadata(MailOperations.overlay(accountId, this.selected)); }
    try {
      const cached = await this.accountStore.mail.view(accountId, this.mailboxId, true, false);
      if (!this.active || generation !== this.generation || revision !== this.operationRevision || viewRevision !== this.inboxViewRevision) { return; }
      let confirmed = cached !== null && cached.stateDirty !== true;
      if (cached) {
        this.emailsDirty = cached.stateDirty === true;
        this.emails = cached.emails.map(mail => MailOperations.overlay(accountId, mail));
        this.refreshRequired = cached.stateDirty === true && MailOperations.count(accountId) === 0;
      }
      if (this.selected) {
        const body = await this.accountStore.mail.email(accountId, MailOperations.currentEmailId(accountId, this.selected.id), true);
        if (!this.active || generation !== this.generation || revision !== this.operationRevision || viewRevision !== this.inboxViewRevision) { return; }
        confirmed = confirmed && body !== null && body.stateDirty !== true;
        if (body) {
          this.applyReaderMetadata(MailOperations.overlay(accountId, body.mail));
          this.refreshRequired = body.stateDirty === true && !MailOperations.pending(accountId, body.mail.id);
        }
      }
      // A temporary uncertain-cache caption must not keep the row actions
      // disabled after acknowledgement. Preserve genuine network fallbacks.
      if (confirmed && this.savedCopyFromDirty) {
        this.savedCopyAt = 0; this.savedCopyFromDirty = false;
      }
      await this.loadConversationIndex(accountId, generation, revision);
    } catch (_) { /* Completion notices remain available independently of the view. */ }
    finally { this.inboxChanged(); }
  }

  private async sendChanged(): Promise<void> {
    this.sendRevision;
    this.refreshUnreadStatus();
    if (!this.active || !this.ready) { return; }
    const notices = BackgroundSend.takeNotices();
    for (const notice of notices) {
      this.getUIContext().getPromptAction().showToast({
        message: `${this.label(notice.label)}${notice.diagnostic ? ` (${notice.diagnostic})` : ''}`
      });
    }
    if (!notices.some(notice => notice.accountId === this.account.id)) { return; }
    const generation = this.generation, accountId = this.account.id;
    const boxes = await this.accountStore.mail.boxes(accountId).catch(() => null);
    if (generation !== this.generation || !this.active) { return; }
    if (boxes) { await this.applyBoxes(boxes.boxes, accountId, generation); }
    if (generation !== this.generation || !this.active) { return; }
    await this.operationsChanged();
  }

  private back(): boolean {
    if (this.changing) { return true; }
    this.pendingSwipeAction?.();
    this.oauthFlow?.cancel(); this.oauthPending = false;
    ++this.generation; ++this.mailboxRefreshRevision; this.mailboxRefreshActive = false; this.refreshing = false;
    this.busy = false; this.readerScrollActive = false; this.messageLoader?.cancel(); AutomaticMailWork.cancelInactive();
    this.error = ''; this.attachmentBusy = ''; return false;
  }

  private async attachmentPath(context: common.UIAbilityContext, accountId: string, mail: JmapEmail,
    attachment: MailAttachment, download: () => Promise<MailAttachmentData>): Promise<string> {
    const origins = Array.from(new Set([mail.cachedSourceId || mail.id, ...(mail.cachedAttachmentSourceIds ?? []), mail.id]));
    // A confirmed IMAP move may have two existing local copies. Try their
    // saved files before making the single explicit download request.
    for (const origin of origins) {
      const draftId = origin.startsWith('local_sent_') ? origin.slice('local_sent_'.length) : '';
      try {
        if (outgoingUUIDValid(draftId) && outgoingUUIDValid(attachment.id)) {
          const file: OutgoingAttachment = { id: attachment.id, name: attachment.name, contentType: attachment.contentType,
            size: attachment.size, file: outgoingAttachmentReference(accountId, draftId, attachment.id) };
          return await new OutgoingAttachmentFiles(context.filesDir).path(accountId, draftId, file);
        }
        return await AttachmentFiles.load(context, accountId, origin, attachment, async () => { throw new Error('No saved attachment'); });
      } catch (_) { /* A missing local copy can use the next confirmed cache origin. */ }
    }
    if (attachment.size > AttachmentFiles.limit) { throw new Error('Attachment exceeds limit'); }
    return AttachmentFiles.load(context, accountId, mail.cachedSourceId || mail.id, attachment, download);
  }

  private async attachmentAction(attachment: MailAttachment, save: boolean): Promise<void> {
    const client = this.client, mail = this.selected;
    if (!mail || this.attachmentBusy !== '' || !this.bodyLoaded) { return; }
    const localAttachment = outgoingUUIDValid(attachment.id);
    if (!localAttachment && attachment.size > AttachmentFiles.limit) { this.attachmentError = this.label('attachment_too_large'); return; }
    const generation = this.generation, accountId = this.account.id, serverId = this.account.serverId, emailId = mail.id;
    const current = (): boolean => this.active && generation === this.generation && this.account.id === accountId && this.selected?.id === emailId;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.attachmentBusy = attachment.id; this.attachmentError = '';
    let downloaded = false;
    try {
      const path = await this.attachmentPath(context, accountId, mail, attachment, async () => {
        if (!current() || !client?.readAttachment || localAttachment || emailId.startsWith('local_')) { throw new Error('Attachment unavailable'); }
        const data = await client.readAttachment(serverId, emailId, attachment.id);
        if (!current()) { throw new Error('Reader changed'); }
        return data;
      });
      downloaded = true;
      if (!current()) { return; }
      if (save) { await AttachmentFiles.save(context, path, attachment.name); }
      else { await AttachmentFiles.open(context, path, attachment.contentType); }
    } catch (_) {
      if (current()) { this.attachmentError = this.label(downloaded ? 'attachment_open_error' : 'attachment_download_error'); }
    } finally { if (current()) { this.attachmentBusy = ''; } }
  }

  @Builder
  private attachmentList() {
    if (this.selected?.attachments && this.selected.attachments.length > 0) {
      Column({ space: 8 }) {
        ForEach(this.selected.attachments, (attachment: MailAttachment) => {
          Row({ space: 8 }) {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                if (this.attachmentBusy === attachment.id) { LoadingProgress().width(22).height(22) }
                else { SymbolGlyph($r('sys.symbol.doc')).fontSize(22).fontColor([$r('app.color.mail_text_secondary')]) }
                Column({ space: 2 }) {
                  Text(attachment.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${attachment.contentType === 'application/pdf' ? 'PDF · ' : ''}${attachment.size >= 1048576 ? (attachment.size / 1048576).toFixed(1) + ' MB' : Math.ceil(attachment.size / 1024) + ' KB'}${attachment.sizeIsEncoded ? ' · ' + this.label('download_size') : ''}`)
                    .fontSize(11).fontColor($r('app.color.mail_text_secondary'))
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              }.width('100%').constraintSize({ minHeight: 56 }).padding({ top: 10, bottom: 10, left: 12, right: 12 })
            }.id(`attachment-${attachment.id}`).layoutWeight(1).borderRadius(12).buttonStyle(ButtonStyleMode.NORMAL)
              .padding(0).backgroundColor($r('app.color.mail_surface'))
              .enabled(this.attachmentBusy === '' && this.bodyLoaded).onClick(() => this.attachmentAction(attachment, false))
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.square_and_arrow_down_1')).fontSize(20).fontColor([$r('app.color.mail_text_primary')])
            }.id(`save-attachment-${attachment.id}`).width(44).height(44).buttonStyle(ButtonStyleMode.NORMAL)
              .accessibilityText(this.label('save_attachment')).enabled(this.attachmentBusy === '' && this.bodyLoaded)
              .onClick(() => this.attachmentAction(attachment, true))
          }.width('100%')
        }, (attachment: MailAttachment) => attachment.id)
        if (this.attachmentError !== '') { Text(this.attachmentError).fontSize(14).fontColor($r('app.color.mail_text_secondary')) }
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  private async archive(mail: JmapEmail): Promise<void> {
    const current = this.emails.find(item => item.id === mail.id);
    if (!current) { return; }
    const client = this.client, target = archiveTarget(current, this.boxes);
    if (!client || !target || this.swipeClosing || (this.busy && !this.mailboxRefreshActive) || this.savedCopyAt !== 0 || MailOperations.pending(this.account.id, mail.id)) { return; }
    const inbox = this.boxes.find(box => box.role === 'inbox');
    if (!inbox) { return; }
    const membership = current.mailboxIds.filter(id => id !== inbox.id);
    if (!membership.includes(target.id)) { membership.push(target.id); }
    const account = this.account, store = this.accountStore, generation = this.generation;
    this.closeSwipeAction(() => {
      MailOperations.move(store, client, account.id, account.serverId, current, membership);
      if (this.active && generation === this.generation && account.id === this.account.id) {
        this.emails = this.emails.map(item => MailOperations.overlay(account.id, item));
      }
    });
  }

  private async undoMove(): Promise<void> {
    const client = this.client, undo = this.archiveUndo;
    if (!client || !undo || this.busy || MailOperations.pending(this.account.id, undo.emailId)) { return; }
    const account = this.account;
    const downloaded = this.conversationIndex.find(item => item.id === undo.emailId);
    const cached = await this.accountStore.mail.email(account.id, undo.emailId, true);
    const mail = cached?.mail || downloaded;
    if (!mail) { return; }
    const membership = undo.expectedMailboxIds.filter(id => !undo.addedArchive || id !== undo.archiveId);
    if (!membership.includes(undo.inboxId)) { membership.push(undo.inboxId); }
    MailOperations.move(this.accountStore, client, account.id, account.serverId, mail, membership, undo);
  }

  @Builder
  private status(showActivity: boolean = true) {
    if (this.savedCopyAt > 0) {
      Text(`${this.label('saved_copy')} · ${new Date(this.savedCopyAt).toLocaleString(AppLanguage.locale)}`)
        .id('saved-copy').fontSize(13).fontColor($r('app.color.mail_text_secondary')).padding(12)
    }
    if (this.cacheWarning) { Text(this.label('cache_save_error')).id('cache-warning').fontSize(13).padding(12) }
    if (showActivity && MailOperations.count(this.account.id) > 0) {
      Text(this.label('changes_pending')).id('changes-pending').fontSize(13).fontColor($r('app.color.mail_text_secondary')).padding(8)
    }
    if (MailOperations.notice(this.account.id)) {
      Text(this.label(MailOperations.notice(this.account.id))).id('operation-notice').fontSize(13).padding(8)
    }
    if (showActivity && this.busy) { LoadingProgress().id('connection-loading').width(32).height(32).margin(12) }
    if (this.error !== '') {
      Text(this.error).id('connection-error').fontSize(15).fontColor($r('app.color.mail_text_primary')).padding(16)
      if (this.error === this.label('account_auth_error') && this.account.authentication === 'oauth' &&
        this.account.sessionUrl === RegisteredMailOAuth.incoming('google') && !RegisteredMailOAuth.googleBrowserSignInEnabled) {
        Text(this.label('gmail_app_password_help')).id('gmail-auth-app-password-help')
          .fontSize(14).fontColor($r('app.color.mail_text_secondary')).padding(16)
      }
      if (this.error === this.label('account_auth_error') && this.reconnectProvider(this.account) !== null) {
        Button(this.label('reconnect_account')).id('reconnect-current-account').enabled(!this.busy)
          .onClick(() => this.reconnectOAuth(this.account))
      }
    }
    if (this.oauthPending) {
      Text(this.label('oauth_waiting')).fontSize(14).padding(8)
      Button(this.label('cancel')).id('oauth-cancel').buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.cancelSignIn())
    }
  }

  private async prepareResponse(mode: string): Promise<void> {
    if (this.busy || !this.selected || !this.account.emailAddress || BackgroundSend.isSending(this.account.id)) { return; }
    const mail = this.selected; const account = this.account; const generation = this.generation;
    this.busy = true;
    try {
      const existing = await this.accountStore.outgoing(account.id);
      if (generation !== this.generation) { return; }
      if (existing && existing.state !== 'sent' && (existing.state !== 'draft' || existing.to || existing.cc || existing.bcc || existing.subject || existing.text || existing.forwardHtml)) {
        this.getUIContext().showAlertDialog({ title: this.label('unfinished_draft'),
          message: this.label('unfinished_draft_detail'),
          primaryButton: { value: this.label('continue_draft'), action: () => {
            if (generation === this.generation) { this.paths.pushPathByName('compose', null); }
          } }, secondaryButton: { value: this.label('cancel'), action: () => {} } });
        return;
      }
      const content = mode === 'forward' ? forwardContent(mail) : replyContent(mail, account.emailAddress, mode === 'replyAll');
      const draft = new OutgoingDraft(); draft.id = util.generateRandomUUID(); draft.date = Date.now();
      draft.to = content.to; draft.cc = content.cc; draft.subject = content.subject; draft.text = content.text;
      draft.inReplyTo = content.inReplyTo; draft.references = content.references;
      draft.forwardHtml = content.forwardHtml; draft.forwardWarning = content.forwardWarning;
      await this.accountStore.prepareNewOutgoing(account.id, draft);
      await this.accountStore.saveOutgoing(account.id, draft);
      if (generation === this.generation) { this.paths.pushPathByName('compose', null); }
    } catch (error) {
      this.getUIContext().getPromptAction().showToast({ message: (error as Error).message === 'forwardTooLarge' ?
        this.label('forward_large') : this.label('response_error') });
    } finally { if (generation === this.generation) { this.busy = false; } }
  }

  @Builder
  private readerMenus() {
    Row({ space: 8 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.arrowshape_turn_up_left')).fontSize(24).fontColor([$r('app.color.mail_text_primary')])
      }.id('reply-mail').width(44).height(44).backgroundColor($r('app.color.mail_surface'))
        .accessibilityText(this.label('reply_forward'))
        .enabled(!this.busy && !BackgroundSend.isSending(this.account.id) && this.bodyLoaded && this.selected !== null && this.account.emailAddress !== '')
        .bindMenu([{ value: this.label('reply'), action: () => this.prepareResponse('reply') },
          { value: this.label('reply_all'), action: () => this.prepareResponse('replyAll') },
          { value: this.label('forward'), action: () => this.prepareResponse('forward') }])
    }
  }

  @Builder
  private readerTitle() {
    Row({ space: 12 }) {
      Button({ type: ButtonType.Circle }) {
        SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(24).fontColor([$r('app.color.mail_text_primary')])
      }.id('reader-back').width(44).height(44).backgroundColor($r('app.color.mail_surface'))
        .accessibilityText(this.currentMailboxTitle()).onClick(() => { if (!this.back()) { this.paths.pop(); } })
      Text(this.label('message')).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.mail_text_primary'))
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      this.readerMenus()
    }.width('100%').height('100%').padding({ left: this.readerCompact ? 16 : this.tablet ? 30 : 20,
      right: this.readerCompact ? 16 : this.tablet ? 30 : 20, top: this.readerCompact ? 4 : 6, bottom: this.readerCompact ? 4 : 6 })
  }

  @Builder
  private addressDetail(label: string, addresses: JmapAddress[]) {
    if (addresses.length > 0) {
      Row({ space: 8 }) {
        Text(label).fontSize(13).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 40 }).maxLines(1)
        Text(addresses.map(address => address.name && address.name !== address.email ?
          `${address.name} <${address.email}>` : address.email).join(', '))
          .fontSize(13).lineHeight(19).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice).layoutWeight(1)
      }.alignItems(VerticalAlign.Top).width('100%')
    }
  }

  @Builder
  private readerHeader() {
    if (this.selected) {
      Column({ space: this.readerCompact ? 14 : this.tablet ? 20 : 18 }) {
        Text(this.selected.subject || this.label('no_subject')).id('reader-subject')
          .fontSize(this.readerCompact ? 22 : 24).lineHeight(this.readerCompact ? 27.5 : 30).fontWeight(FontWeight.Bold).width('100%')
          .fontColor($r('app.color.mail_text_primary'))
          .wordBreak(WordBreak.BREAK_WORD).copyOption(CopyOptions.LocalDevice)
        Column({ space: 0 }) {
          Flex({ direction: this.readerCompact ? FlexDirection.Column : FlexDirection.Row, alignItems: this.readerCompact ? ItemAlign.Start : ItemAlign.Baseline }) {
            Text(this.selected.from.map(address => address.name || address.email).join(', '))
              .fontSize(this.readerCompact ? 16 : 17).lineHeight(this.readerCompact ? 22.4 : 23.8).fontWeight(FontWeight.Medium).flexGrow(1)
              .fontColor($r('app.color.mail_text_primary'))
              .margin({ right: this.readerCompact ? 0 : 12 })
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.dateLabel(this.selected.receivedAt))
              .fontSize(12).fontColor($r('app.color.mail_text_secondary')).maxLines(1)
          }.width('100%')
          Button({ type: ButtonType.Normal }) {
            Row({ space: 8 }) {
              Text(`${this.label('to_field')} ${this.selected.to.map(address => address.name || address.email).join(', ')}`)
                .fontSize(14).fontColor($r('app.color.mail_text_secondary')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              SymbolGlyph(this.readerDetails ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
                .fontSize(16).fontColor([$r('app.color.mail_text_secondary')])
            }.width('100%')
          }.id('reader-details-toggle').width('100%').constraintSize({ minHeight: 44 })
            .backgroundColor(Color.Transparent).borderRadius(8).padding(0).margin({ top: 2, bottom: 8 })
            .accessibilityText(`${this.label('to_field')} ${this.selected.to.map(address => address.name || address.email).join(', ')}. ${this.label(this.readerDetails ? 'hide_message_details' : 'show_message_details')}`)
            .onClick(() => this.readerDetails = !this.readerDetails)
          if (this.readerDetails) {
            Column({ space: 7 }) {
              this.addressDetail(this.label('from_field'), this.selected.from)
              this.addressDetail(this.label('to_field'), this.selected.to)
              this.addressDetail(this.label('cc_field'), this.selected.cc || [])
              Text(new Date(this.selected.receivedAt).toLocaleString(AppLanguage.locale))
                .fontSize(13).fontColor($r('app.color.mail_text_secondary')).width('100%')
            }.id('reader-details').width('100%').alignItems(HorizontalAlign.Start).padding({ bottom: 12 })
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  private isSent(mail: JmapEmail): boolean {
    return mail.from.some(address => address.email.toLowerCase() === this.account.emailAddress.toLowerCase()) ||
      mail.mailboxIds.some(id => this.boxes.some(box => box.id === id && box.role === 'sent'));
  }

  @Builder
  private collapsedMessage(mail: JmapEmail) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text(mail.from.map(address => address.name || address.email).join(', '))
          .fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.mail_text_primary'))
          if (this.isSent(mail)) { Text(this.label('sent')).fontSize(12).fontColor($r('app.color.mail_accent')) }
          Text(this.dateLabel(mail.receivedAt)).fontSize(12).fontColor($r('app.color.mail_text_secondary'))
          SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(12).fontColor([$r('app.color.mail_text_secondary')])
        }.width('100%').constraintSize({ minHeight: 44 })
      }.alignItems(HorizontalAlign.Start).width('100%')
    }.id(`conversation-message-${mail.id}`).width('100%').constraintSize({ minHeight: 76 })
      .backgroundColor($r('app.color.mail_surface')).borderRadius(12)
      .padding(16).margin({ top: 10, bottom: 10 })
      .enabled(!this.busy).onClick(() => this.read(mail, true))
  }

  @Builder
  private expandedMessage() {
    Column() {
      Column({ space: 0 }) {
        if (this.selected) {
          if (this.isSent(this.selected)) { Text(this.label('sent')).fontSize(13).fontColor($r('app.color.mail_accent')) }
          this.readerHeader()
          this.attachmentList()
          if (this.selected.bodyTruncated || this.selected.bodyEncodingProblem) {
            Text(this.label('partial_body')).fontSize(14).fontColor($r('app.color.mail_text_secondary'))
          }
          if (this.bodyLoaded && !this.selected.htmlBody && this.selected.textBody === null) {
            Text(this.label('no_plain_body')).fontSize(16)
          }
        }
      }.alignItems(HorizontalAlign.Start).width('100%').padding({ bottom: 8 })
      if (this.bodyLoaded && this.selected && (this.readerDocument || this.selected.htmlBody || this.selected.textBody !== null)) {
        HtmlMail({ html: this.readerDocument ? '' : (this.selected.htmlBody || plainTextMailHtml(this.selected.textBody || '')), fitContent: true,
          messageKey: stableMessageKey(this.selected), accountId: this.account.id, pictureCache: this.accountStore.pictures,
          savedDocument: this.readerDocument || undefined, readerVisible: this.readerVisible, contentInset: 0 }).width('100%')
      }
    }.id('expanded-message').width('100%')
  }

  @Builder
  private destinations(name: string) {
    if (name === 'settings') {
      NavDestination() { Settings({ account: this.account, store: this.accountStore }) }.title(this.label('settings'))
    } else if (name === 'compose') {
      NavDestination() {
        ComposeMail({ account: this.account, store: this.accountStore, tabletLayout: this.tablet, onQueued: () => {
          if (this.openInboxOnLaunch) { this.paths.clear(false); }
          else { while (this.paths.getAllPathName().includes('compose') || this.paths.getAllPathName().includes('read')) { this.paths.pop(); } }
          this.openNotification();
          this.inboxChanged();
        }, onClose: (sent: boolean) => {
          this.paths.pop();
          this.openNotification();
          this.inboxChanged();
          if (sent) { this.getUIContext().getPromptAction().showToast({ message: this.label('sent') }); }
        } })
      }.hideTitleBar(true).backgroundColor($r('app.color.mail_background')).clip(true)
    } else if (name === 'accounts') {
      NavDestination() { this.accountForm() }.title(this.label('accounts')).onBackPressed(() => this.back())
    } else if (name === 'boxes') {
      NavDestination() {
        Column() {
          this.status()
          Text(this.account.name).fontSize(14).fontColor($r('app.color.mail_text_secondary')).padding(16)
          List() {
            ForEach(this.boxes, (box: JmapMailbox) => {
              ListItem() {
                Row() {
                  Text(this.boxLabel(box)).layoutWeight(1).fontSize(18)
                  if (this.mailboxHasUnread(box.id)) {
                    Circle().id(`mailbox-unread-${box.id}`).width(8).height(8).fill('#E84026')
                      .margin({ right: 8 }).accessibilityText(this.label('unread'))
                  }
                  if (box.countsKnown !== false) {
                    Text(`${box.unreadEmails}`).fontColor($r('app.color.mail_text_secondary'))
                  }
                }.padding(20).width('100%').constraintSize({ minHeight: 64 })
                .backgroundColor($r('app.color.mail_surface')).borderRadius(16)
              }.id(`remote-box-${box.id}`).onClick(() => this.openBox(box)).enabled(!this.busy)
            }, (box: JmapMailbox) => `${box.id}-${JSON.stringify(box)}`)
          }.layoutWeight(1)
          Button(this.label('settings')).id('open-settings').width('100%').margin({ top: 12 })
            .onClick(() => this.paths.pushPathByName('settings', null))
          Button(this.label('accounts')).id('open-accounts').width('100%').margin({ top: 16 })
            .onClick(() => this.paths.pushPathByName('accounts', null))
        }.padding(20).height('100%').width('100%')
      }.title(this.label('mailboxes')).onBackPressed(() => this.back())
      .onShown(() => { if (this.boxesDirty) { this.loadBoxes(false); } }).menus([
        { value: this.label('refresh'), symbolIcon: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise')), action: () => this.loadBoxes(false) }
      ])
    } else if (name === 'emails') {
      NavDestination() {
        this.messageList()
      }.title(this.boxName).onBackPressed(() => this.back())
      .onShown(() => { this.inboxVisibilityChanged(true); if (this.emailsDirty) { this.loadPage(true); } })
      .onHidden(() => this.inboxVisibilityChanged(false))
    } else if (name === 'read') {
      NavDestination() {
        Scroll() {
          Column() {
          this.status()
          if (!this.bodyLoaded && this.selected !== null && !this.busy) {
            Text(this.label('body_not_saved')).id('body-not-saved').fontSize(14)
              .fontColor($r('app.color.mail_text_secondary')).padding({ bottom: 12 })
            Button(this.label('retry')).id('retry-message')
              .onClick(() => { if (this.selected) { this.read(this.selected, true); } })
          }
          ForEach(this.conversation, (mail: JmapEmail) => {
            if (this.selected?.id === mail.id) { this.expandedMessage() }
            else { this.collapsedMessage(mail) }
          }, (mail: JmapEmail) => mail.id)
          }.id('reader-column').width('100%').constraintSize({ maxWidth: 760 })
            .padding({ left: this.readerCompact ? 16 : 20, right: this.readerCompact ? 16 : 20,
              top: this.readerCompact ? 8 : this.tablet ? 24 : 10, bottom: this.tablet ? 48 : 24 })
        }.id('reader-scroll').width('100%').height('100%').align(Alignment.Top)
          .onScrollStart(() => {
            if (this.readerVisible && MailInboxUpdates.isForeground()) { this.readerScrollActive = true; AutomaticMailWork.cancelInactive(); }
          })
          .onScrollStop(() => { this.readerScrollActive = false; this.inboxChanged(); })
          .onAreaChange((_, area) => { this.readerCompact = Number(area.width) < 360 || Number(area.height) < 500; })
      }.title({ builder: this.readerTitle, height: this.readerCompact ? 52 : 60 })
        .hideBackButton(true).onBackPressed(() => this.back())
        .onShown(() => this.readerVisibilityChanged(true)).onHidden(() => this.readerVisibilityChanged(false))
    }
  }

  private async refreshMailbox(): Promise<void> {
    if (this.busy || !this.client) {
      if (!this.mailboxRefreshActive) { this.refreshing = false; }
      return;
    }
    this.mailboxRefreshActive = true; this.refreshing = true;
    const accountId = this.account.id, revision = ++this.mailboxRefreshRevision;
    const current = (): boolean => this.active && this.account.id === accountId && this.mailboxRefreshRevision === revision;
    try {
      // Older caches predate SPECIAL-USE Sent roles. Upgrade that metadata on
      // the first explicit refresh, keeping offline launch request-free.
      if (this.account.sessionUrl.startsWith('imaps:') && !this.boxRolesCurrent && this.mailboxId !== '') {
        await this.loadBoxes(false);
        if (!current()) { return; }
      }
      if (this.mailboxId === '') {
        await this.loadBoxes(false);
        if (!current()) { return; }
        const inbox = this.boxes.find(box => box.role === 'inbox');
        if (inbox) { await this.openBox(inbox, false); }
      } else { await this.loadPage(true); }
      if (current()) { MailOperations.clearNotices(accountId); }
    }
    finally {
      if (current()) { this.mailboxRefreshActive = false; this.refreshing = false; this.updateSearchPosition(); this.inboxChanged(); }
    }
  }

  private boxLabel(box: JmapMailbox): string {
    if (box.id === LOCAL_SENT_MAILBOX) { return this.label('sent_on_device'); }
    if (box.role && ['inbox', 'drafts', 'sent', 'trash', 'junk', 'archive'].includes(box.role)) { return this.label(box.role); }
    return box.name;
  }

  private dateLabel(value: number): string {
    const date = new Date(value);
    return date.toDateString() === new Date().toDateString() ?
      date.toLocaleTimeString(AppLanguage.locale, { hour: '2-digit', minute: '2-digit' }) :
      date.toLocaleDateString(AppLanguage.locale, { month: 'short', day: 'numeric' });
  }

  private visibleEmails(): JmapEmail[] {
    this.conversationRevision;
    const query = this.query.trim().toLocaleLowerCase();
    const visited = new Set<string>();
    const result: JmapEmail[] = [];
    const messages = this.emails.map(mail => MailOperations.overlay(this.account.id, mail))
      .filter(mail => mail.mailboxIds.includes(this.mailboxId));
    const byId = new Map<string, number[]>(), byMessageId = new Map<string, number[]>();
    messages.forEach((mail, index) => {
      const copies = byId.get(mail.id) || []; copies.push(index); byId.set(mail.id, copies);
      for (const id of mail.messageIds) {
        const copies = byMessageId.get(id) || []; copies.push(index); byMessageId.set(id, copies);
      }
    });
    const members = new Map<JmapEmail[], JmapEmail[]>();
    const unread = new Map<JmapEmail[], JmapEmail | null>();
    const matches = new Map<JmapEmail[], boolean>();
    for (const mail of messages) {
      if (visited.has(mail.id)) { continue; }
      const thread = this.conversationById.get(mail.id) || [mail];
      let inFolder = members.get(thread);
      if (!inFolder) {
        // Find folder copies by identity once per thread. Scanning the entire
        // mailbox for every row made ordinary unthreaded inboxes quadratic.
        const positions = new Set<number>();
        for (const item of thread) {
          for (const index of byId.get(item.id) || []) { positions.add(index); }
          for (const id of item.messageIds) {
            for (const index of byMessageId.get(id) || []) { positions.add(index); }
          }
        }
        inFolder = Array.from(positions).sort((a, b) => a - b).map(index => messages[index]);
        members.set(thread, inFolder);
        unread.set(thread, inFolder.find(item => !item.keywords.includes('$seen')) || null);
        matches.set(thread, query === '' || thread.some(item =>
          `${item.subject} ${item.preview} ${item.from.map(address => `${address.name} ${address.email}`).join(' ')}`.toLocaleLowerCase().includes(query)));
      }
      const shown = this.unreadOnly ? unread.get(thread) : mail;
      if (!shown || !matches.get(thread)) { continue; }
      inFolder.forEach(item => visited.add(item.id));
      // Opening a filtered conversation must open an unread member. Otherwise
      // its newest already-read member appears forever despite repeated visits.
      result.push(shown);
    }
    return result;
  }

  private toggleUnread(): void {
    this.pendingSwipeAction?.();
    this.unreadOnly = !this.unreadOnly;
    // The filtered list can be much shorter than the previous scroll offset.
    this.mailScroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }

  private conversationCount(mail: JmapEmail): number {
    this.conversationRevision;
    return this.conversationById.get(mail.id)?.length || 1;
  }

  private mailRowKey(mail: JmapEmail): string {
    // Only rendered text and action state can replace a native row. Downloading
    // a body or refreshing thread metadata must not reset its swipe/scroll node,
    // or serialize large HTML documents on every list update.
    return JSON.stringify([this.account.id, mail.id, mail.from, mail.subject, mail.preview,
      mail.receivedAt, mail.keywords.includes('$seen'), mail.keywords.includes('$flagged'),
      mail.mailboxIds, mail.maySetSeen, mail.maySetKeywords, this.conversationCount(mail)]);
  }

  private rowAllows(mail: JmapEmail, keyword: JmapKeyword): boolean {
    // Pending jobs are outside ArkUI state. Re-evaluate native button enabled
    // bindings on acknowledgement even when the optimistic mail key is unchanged.
    this.operationRevision;
    // A header refresh does not own the cached row's actions. MailOperations
    // records a mutation revision so an older page cannot undo the local flag.
    return (!this.busy || this.mailboxRefreshActive) && !this.swipeClosing && !MailOperations.pending(this.account.id, mail.id) && !mail.id.startsWith('local_') && !this.readOnly && !this.refreshRequired && this.savedCopyAt === 0 &&
      (this.account.sessionUrl.startsWith('imaps:') || canSetKeyword(mail, this.boxes, keyword));
  }

  private rowArchiveAllows(mail: JmapEmail): boolean {
    this.operationRevision;
    return (!this.busy || this.mailboxRefreshActive) && !this.swipeClosing && !MailOperations.pending(this.account.id, mail.id) &&
      this.savedCopyAt === 0 && archiveTarget(mail, this.boxes) !== null;
  }

  private async rowKeyword(mail: JmapEmail, keyword: JmapKeyword): Promise<void> {
    const current = this.emails.find(item => item.id === mail.id), client = this.client;
    if (!current || !client || !this.rowAllows(current, keyword)) { return; }
    const account = this.account, store = this.accountStore, generation = this.generation;
    this.closeSwipeAction(() => {
      MailOperations.setKeyword(store, client, account.id, account.serverId, current, keyword);
      if (this.active && generation === this.generation && account.id === this.account.id) {
        this.emails = this.emails.map(item => MailOperations.overlay(account.id, item));
      }
    });
  }

  private closeSwipeAction(action: () => void): void {
    if (this.swipeClosing) { return; }
    this.swipeClosing = true;
    let completed = false;
    let closeTimeout: number = -1;
    const finish = (): void => {
      if (completed) { return; }
      if (closeTimeout >= 0) { clearTimeout(closeTimeout); }
      completed = true; this.pendingSwipeAction = null; this.inboxSwipes.clear(); this.swipeClosing = false;
      action();
    };
    this.pendingSwipeAction = finish;
    // Keep the pressed native ListItem alive until its action panel collapses.
    // The background acknowledgement can then replace its displayed flags.
    // Interrupted or not-yet-expanded native panels may omit onFinish. Keep
    // the accepted action bounded; this submits once and never retries it.
    closeTimeout = setTimeout(finish, 1000);
    try { this.mailScroller.closeAllSwipeActions({ onFinish: finish }); }
    catch (_) { finish(); }
  }

  @Builder
  private swipeRead(mail: JmapEmail) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.envelope')).fontSize(24).fontColor([Color.White])
        Text(this.label(mail.keywords.includes('$seen') ? 'mark_unread' : 'mark_read')).fontSize(13).fontColor(Color.White).maxLines(2).textAlign(TextAlign.Center)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
    }.id(`swipe-read-${mail.id}`).width(88)
      .height(Math.max(44, this.rowContentHeights.get(`${this.account.id}:${mail.id}`) || 0))
      .padding(0).borderRadius(0).backgroundColor($r('app.color.mail_accent'))
      .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
      .enabled(this.rowAllows(mail, '$seen')).onClick(() => this.rowKeyword(mail, '$seen'))
  }

  @Builder
  private swipeMore(mail: JmapEmail) {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          SymbolGlyph(mail.keywords.includes('$flagged') ? $r('sys.symbol.star_fill') : $r('sys.symbol.star')).fontSize(24).fontColor([Color.White])
          Text(this.label(mail.keywords.includes('$flagged') ? 'unstar' : 'star')).fontSize(13).fontColor(Color.White).maxLines(2)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
      }.id(`swipe-star-${mail.id}`).width(76)
        .height(Math.max(44, this.rowContentHeights.get(`${this.account.id}:${mail.id}`) || 0))
        .padding(0).borderRadius(0).backgroundColor('#A66B00')
        .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
        .enabled(this.rowAllows(mail, '$flagged')).onClick(() => this.rowKeyword(mail, '$flagged'))
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(24).fontColor([Color.White])
          Text(this.label('archive')).fontSize(13).fontColor(Color.White).maxLines(2)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
      }.id(`swipe-archive-${mail.id}`).width(76)
        .height(Math.max(44, this.rowContentHeights.get(`${this.account.id}:${mail.id}`) || 0))
        .padding(0).borderRadius(0).backgroundColor('#46656A')
        .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
        .enabled(this.rowArchiveAllows(mail))
        .onClick(() => this.archive(mail))
    }.height(Math.max(44, this.rowContentHeights.get(`${this.account.id}:${mail.id}`) || 0))
  }

  @Builder
  private unreadMarker(mail: JmapEmail) {
    if (!mail.keywords.includes('$seen')) {
      Row().id(`unread-marker-${mail.id}`).width(3)
        .height(Math.max(0, (this.rowContentHeights.get(`${this.account.id}:${mail.id}`) || 0) - (this.compact ? 24 : 32)))
        .borderRadius(2).backgroundColor($r('app.color.mail_accent'))
        .position({ x: 0, y: this.compact ? 12 : 16 })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  private mailRow(mail: JmapEmail) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Text(mail.from.map(address => address.name || address.email).join(', '))
            .fontSize(16).lineHeight(19.2).fontWeight((!mail.keywords.includes('$seen')) ? FontWeight.Bold : FontWeight.Medium)
            .fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.dateLabel(mail.receivedAt)).fontSize(12).fontColor($r('app.color.mail_text_secondary'))
        }
        Row({ space: 8 }) {
          Text(mail.subject || this.label('no_subject')).fontSize(16).lineHeight(21.6)
            .fontWeight((!mail.keywords.includes('$seen')) ? FontWeight.Bold : FontWeight.Normal).layoutWeight(1)
            .fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.conversationCount(mail) > 1) {
            Text(`${this.conversationCount(mail)}`).id(`conversation-count-${mail.id}`).fontSize(12)
              .fontColor($r('app.color.mail_text_secondary')).padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.mail_surface')).borderRadius(12)
          }
        }.width('100%')
        Row({ space: 6 }) {
          Text(mail.preview.replace(/\s+/g, ' ')).fontSize(14).lineHeight(20.3).fontColor($r('app.color.mail_text_secondary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (mail.keywords.includes('$flagged')) {
            SymbolGlyph($r('sys.symbol.star')).id(`remote-star-${mail.id}`).fontSize(14).fontColor([$r('app.color.mail_accent')]).margin({ top: 3 })
          }
        }.alignItems(VerticalAlign.Top)
      }.alignItems(HorizontalAlign.Start).width('100%')
        .padding({ top: this.compact ? 12 : 16, bottom: this.compact ? 12 : 16, left: this.compact ? 16 : 20, right: this.compact ? 16 : 20 })
        .onAreaChange((_, area) => {
          const key = `${this.account.id}:${mail.id}`;
          const height = Number(area.height);
          if (height > 0 && Math.abs((this.rowContentHeights.get(key) || 0) - height) > 0.5) {
            const measured = new Map(this.rowContentHeights);
            measured.set(key, height); this.rowContentHeights = measured;
          }
        })
      // A finite height measured from the text cannot expand the row to the
      // list viewport, unlike percentage sizing in an intrinsically sized Stack.
      this.unreadMarker(mail)
    }.width('100%')
    .onClick(() => { if (!this.swipeClosing) { this.read(mail); } })
    .accessibilityGroup(true)
    .accessibilityText(`${(!mail.keywords.includes('$seen')) ? `${this.label('unread')}. ` : ''}${mail.from.map(address => address.name || address.email).join(', ')}. ${mail.subject}. ${mail.keywords.includes('$flagged') ? this.label('starred') : ''}`)
  }

  @Builder
  private accountPickerItem(account: SavedAccount) {
    Row({ space: 12 }) {
      Text(account.emailAddress || account.name).fontSize(16).layoutWeight(1)
        .fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.accountHasUnread(account.id)) {
        Circle().id(`account-unread-${account.id}`).width(8).height(8).fill('#E84026')
          .accessibilityText(this.label('unread'))
      }
    }.width('100%').constraintSize({ minHeight: 44 })
  }

  @Builder
  private accountPicker() {
    Menu() {
      ForEach(this.accounts, (account: SavedAccount) => {
        MenuItem(this.accountPickerItem.bind(this, account))
          .id(`switch-account-${account.id}`).selected(account.id === this.account.id).selectIcon(true)
          .enabled(true)
          .onClick(() => { if (account.id !== this.account.id) { this.openAccount(account, true); } })
      }, (account: SavedAccount) => account.id)
    }.id('account-picker').width(this.tablet ? 320 : undefined)
  }

  private resetInboxScroll(): void {
    this.rowContentHeights = new Map();
    this.searchInteracted = false; this.searchVisible = false;
    this.inboxPullActive = false;
    this.inboxFirstVisible = 0; ++this.inboxScrollRevision;
    if (this.mailScroller.currentOffset()) { this.mailScroller.scrollTo({ xOffset: 0, yOffset: 0 }); }
  }

  private updateSearchPosition(): void {
    // Resizing the header while the native List/Refresh owns a gesture changes
    // its viewport and pull offset mid-animation. Settle first, then reveal it.
    if (this.inboxScrollActive || this.inboxPullActive || this.mailboxRefreshActive || this.refreshing || this.swipeClosing || this.inboxSwipes.size > 0) { return; }
    const offset = this.mailScroller.currentOffset();
    if (offset) { this.searchVisible = this.searchInteracted && offset.yOffset <= 0.5; }
  }

  @Builder
  private mailboxHeader() {
    Column() {
      Row({ space: 12 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(this.account.emailAddress || this.account.name).id('inbox-account-label')
              .fontSize(13).fontColor($r('app.color.mail_text_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            if (this.accountHasUnread(this.account.id)) {
              Circle().id('inbox-unread-dot').width(8).height(8).fill('#E84026')
                .accessibilityText(this.label('unread'))
            }
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(14).fontColor([$r('app.color.mail_text_secondary')])
          }.width('100%')
        }.id('inbox-account').layoutWeight(1).height(44).padding(0).backgroundColor(Color.Transparent)
          .enabled(this.accounts.length > 0 && !this.paths.getAllPathName().includes('compose'))
          .accessibilityText(`${this.label('switch_account')}, ${this.account.emailAddress || this.account.name}`)
          .bindMenu(this.accountPicker)
        Button(this.unreadOnly ? this.label('show_all') : this.label('unread'), { type: ButtonType.Capsule })
          .id('filter-unread')
          .buttonStyle(ButtonStyleMode.NORMAL).fontSize(14).fontColor($r('app.color.mail_text_primary'))
          .height(this.compact ? 36 : 40).constraintSize({ minWidth: this.compact ? 74 : 78 }).padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.mail_surface'))
          .onClick(() => this.toggleUnread())
          .accessibilityText(this.label('filter_unread'))
      }.width('100%')
      Column() {
        Search({ value: this.query, placeholder: this.label('search_loaded_mail') })
          .id('search-mail').onChange((value: string) => { this.query = value; this.updateSearchPosition(); }).height(44)
          .margin({ top: 12 })
      }.id('inbox-search-reveal').width('100%')
        .height(this.searchVisible || this.query.length > 0 ? 56 : 0)
        .opacity(this.searchVisible || this.query.length > 0 ? 1 : 0).clip(true)
        .hitTestBehavior(this.searchVisible || this.query.length > 0 ? HitTestMode.Default : HitTestMode.None)
        .accessibilityLevel(this.searchVisible || this.query.length > 0 ? 'auto' : 'no-hide-descendants')
        .animation({ duration: 180, curve: Curve.EaseOut })
    }.padding({ left: this.compact ? 16 : 20, right: this.compact ? 16 : 20, bottom: this.compact ? 3 : 7 })
  }

  @Builder
  private messageList() {
        Column() {
          this.mailboxHeader()
          // Native Refresh owns pull feedback; transient activity must not add
          // another spinner or shift the list above the user's finger.
          this.status(false)
          NotificationInboxPrompt({ accountId: this.account.id, store: this.accountStore })
          Refresh({ refreshing: $$this.refreshing }) {
            List({ scroller: this.mailScroller }) {
              if (this.busy && !this.mailboxRefreshActive && !this.refreshing && this.emails.length === 0) {
                ListItem() {
                  Row() { LoadingProgress().id('inbox-loading').width(32).height(32) }
                    .width('100%').justifyContent(FlexAlign.Center).padding(20)
                }
              }
              ForEach(this.visibleEmails(), (mail: JmapEmail) => {
                ListItem() { this.mailRow(mail) }
                  .id(`remote-mail-${mail.id}`).enabled(this.client !== null)
                  .swipeAction({ start: this.swipeRead.bind(this, mail), end: this.swipeMore.bind(this, mail), edgeEffect: SwipeEdgeEffect.None,
                    onOffsetChange: (offset: number) => {
                      if (!this.inboxVisible || !MailInboxUpdates.isForeground()) { return; }
                      const key = `${this.account.id}:${mail.id}`;
                      if (Math.abs(offset) > 0.5) { this.inboxSwipes.add(key); }
                      else { this.inboxSwipes.delete(key); this.inboxChanged(); }
                    } })
              }, (mail: JmapEmail) => this.mailRowKey(mail))
              if (this.mailboxId !== '' && this.nextPosition !== null) {
                ListItem() { Button(this.label('load_more')).onClick(() => this.loadPage(false)).enabled(!this.busy).margin(20) }
              }
              if (!this.busy && this.visibleEmails().length === 0 && this.nextPosition === null && this.error === '') {
                ListItem() {
                  Column({ space: 12 }) {
                    SymbolGlyph($r('sys.symbol.envelope')).fontSize(48).fontColor([$r('app.color.mail_text_secondary')])
                    Text(this.label(this.query.length > 0 ? 'no_results' : 'all_clear')).fontSize(22)
                    Text(this.label(this.query.length > 0 ? 'try_search' : 'empty_folder'))
                      .fontSize(16).fontColor($r('app.color.mail_text_secondary'))
                  }.padding(48).width('100%').justifyContent(FlexAlign.Center)
                }
              }
            }.id('mail-list').width('100%').height('100%')
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .divider({ strokeWidth: 1, color: $r('app.color.mail_divider'), startMargin: this.compact ? 16 : 20, endMargin: this.compact ? 16 : 20 })
            .onScrollFrameBegin((offset: number, state: ScrollState) => {
              if (this.inboxVisible && MailInboxUpdates.isForeground() && state === ScrollState.Scroll && Math.abs(offset) > 0.5) {
                this.inboxScrollActive = true; ++this.inboxScrollRevision;
                this.searchInteracted = true;
              }
              return { offsetRemain: offset };
            })
            .onScrollIndex((start: number) => { this.inboxFirstVisible = start; })
            .onScrollStop(() => { this.inboxScrollActive = false; this.updateSearchPosition(); this.inboxChanged(); })
          }.id('mail-refresh').layoutWeight(1).width('100%')
          .refreshOffset(80)
          .pullToRefresh(this.client !== null)
          .onOffsetChange((offset: number) => {
            if (!this.inboxVisible || !MailInboxUpdates.isForeground()) { return; }
            this.inboxPullActive = Math.abs(offset) > 0.5;
            if (offset > 8) { this.searchInteracted = true; }
            if (!this.inboxPullActive) { this.updateSearchPosition(); this.inboxChanged(); }
          })
          .onRefreshing(() => this.refreshMailbox())
          if (this.moveNotice !== '') {
            Row({ space: 12 }) {
              Text(this.moveNotice).fontSize(14).layoutWeight(1)
              if (this.archiveUndo !== null) {
                Button(this.label('undo')).id('undo-archive').buttonStyle(ButtonStyleMode.TEXTUAL)
                  .onClick(() => this.undoMove()).enabled(!this.busy && this.savedCopyAt === 0)
              }
            }.padding(16).width('100%').backgroundColor($r('app.color.mail_surface'))
          }
        }.height('100%').width('100%')
  }

  @Builder
  private discoveryResults(config: MailConfiguration) {
    Column({ space: 12 }) {
      Text(config.name).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      Text(this.label(config.source === 'ISPDB' ? 'discovery_source_ispdb' : 'discovery_source_provider'))
        .fontSize(13).fontColor($r('app.color.mail_text_secondary')).width('100%')
      if (config.incoming.length > 0) {
        Text(this.label('discovery_incoming')).width('100%')
        Select(config.incoming.map((server: DiscoveredServer): SelectOption => ({ value: this.serverChoiceLabel(server) })))
          .id('discovery-incoming').selected(this.incomingChoice).value(this.serverChoiceLabel(config.incoming[this.incomingChoice]))
          .onSelect((index: number) => this.incomingChoice = index).width('100%')
        Text(config.incoming[this.incomingChoice].username).id('discovery-incoming-login').width('100%').fontSize(14)
        if (!config.incoming[this.incomingChoice].supported) {
          Text(this.discoveryReason(config.incoming[this.incomingChoice])).id('discovery-incoming-unavailable').fontSize(14).width('100%')
        }
      }
      if (config.outgoing.length > 0) {
        Text(this.label('discovery_outgoing')).width('100%')
        Select(config.outgoing.map((server: DiscoveredServer): SelectOption => ({ value: this.serverChoiceLabel(server) })))
          .id('discovery-outgoing').selected(this.outgoingChoice).value(this.serverChoiceLabel(config.outgoing[this.outgoingChoice]))
          .onSelect((index: number) => this.outgoingChoice = index).width('100%')
        Text(config.outgoing[this.outgoingChoice].username).width('100%').fontSize(14)
        if (!config.outgoing[this.outgoingChoice].supported) {
          Text(this.discoveryReason(config.outgoing[this.outgoingChoice])).fontSize(14).width('100%')
        }
      }
      Button(this.label('discovery_apply'), { type: ButtonType.Capsule }).id('discovery-apply').width('100%')
        .enabled(!this.busy && config.incoming.length > 0 && config.incoming[this.incomingChoice].supported)
        .onClick(() => this.applyDiscovered())
    }.padding(16).width('100%').backgroundColor($r('app.color.mail_surface')).borderRadius(16)
  }

  @Builder
  private accountForm() {
      Scroll() {
        Column({ space: 16 }) {
          this.status()
          ForEach(this.accounts, (account: SavedAccount) => {
            Row({ space: 8 }) {
              Button(account.name).id(`account-${account.id}`).buttonStyle(ButtonStyleMode.TEXTUAL)
                .layoutWeight(1).onClick(() => this.openAccount(account)).enabled(!this.busy)
              if (this.reconnectProvider(account) !== null) {
                Button(this.label('reconnect_account')).id(`reconnect-${account.id}`)
                  .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy).onClick(() => this.reconnectOAuth(account))
              }
              Button(this.label('disconnect')).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy)
                .onClick(() => this.getUIContext().showAlertDialog({ title: this.label('disconnect'),
                  message: this.label('disconnect_detail'),
                  primaryButton: { value: this.label('cancel'), action: () => {} },
                  secondaryButton: { value: this.label('disconnect'), action: () => this.removeAccount(account) } }))
            }.padding(8).backgroundColor($r('app.color.mail_surface')).borderRadius(16)
          }, (account: SavedAccount) => account.id)
          Button(this.label('settings')).id('account-settings').onClick(() => this.paths.pushPathByName('settings', null))
          Text(this.label('add_account')).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
          Select([{ value: 'IMAP' }, { value: 'JMAP' }]).id('account-protocol')
            .selected(this.protocol === 'imap' ? 0 : 1).value(this.protocol === 'imap' ? 'IMAP' : 'JMAP')
            .onSelect((index: number) => { this.protocol = index === 0 ? 'imap' : 'jmap'; this.candidates = []; this.token = ''; this.serverUrl = ''; this.clearDiscovery(); })
            .enabled(!this.busy).width('100%')
          Text(this.label(this.protocol === 'imap' ? 'imap_setup_help' : 'jmap_setup_help'))
            .fontSize(14).fontColor($r('app.color.mail_text_secondary')).width('100%')
          if (this.protocol === 'imap') {
            TextInput({ text: this.emailAddress, placeholder: this.label('imap_email_address') }).id('account-email-address')
              .type(InputType.Email).enableAutoFill(false).onChange((value) => { this.emailAddress = value; this.candidates = []; this.clearDiscovery(); }).enabled(!this.busy).height(52)
            if (RegisteredMailOAuth.googleBrowserSignInEnabled) {
              Button(this.label('oauth_google'), { type: ButtonType.Capsule }).id('oauth-google').width('100%')
                .buttonStyle(ButtonStyleMode.NORMAL).enabled(this.ready && !this.busy && this.emailAddress.trim() !== '')
                .onClick(() => this.signIn('google'))
            } else {
              Text(this.label('gmail_app_password_help')).id('gmail-app-password-help')
                .fontSize(14).fontColor($r('app.color.mail_text_secondary')).width('100%')
            }
            Button(this.label('oauth_microsoft'), { type: ButtonType.Capsule }).id('oauth-microsoft').width('100%')
              .buttonStyle(ButtonStyleMode.NORMAL).enabled(this.ready && !this.busy && this.emailAddress.trim() !== '')
              .onClick(() => this.signIn('microsoft'))
            Button(this.label('discovery_find'), { type: ButtonType.Capsule }).id('find-server-settings').width('100%')
              .buttonStyle(ButtonStyleMode.NORMAL).enabled(this.ready && !this.busy && this.emailAddress.trim() !== '')
              .onClick(() => this.findSettings())
            if (this.discovered !== null) { this.discoveryResults(this.discovered) }
          }
          TextInput({ text: this.serverUrl, placeholder: this.label(this.protocol === 'imap' ? 'imap_server' : 'server_address') }).id('account-server')
            .onChange((value) => { this.serverUrl = value; this.candidates = []; }).enabled(!this.busy).height(52)
          if (this.protocol === 'imap') {
            TextInput({ text: this.port, placeholder: this.label('imap_port') }).id('account-port').type(InputType.Number)
              .onChange((value) => { this.port = value; this.candidates = []; }).enabled(!this.busy).height(52)
            TextInput({ text: this.username, placeholder: this.label('imap_username') }).id('account-username')
              .enableAutoFill(false).onChange((value) => { this.username = value; this.candidates = []; }).enabled(!this.busy).height(52)
          }
          TextInput({ text: this.token, placeholder: this.label(this.protocol === 'imap' ? 'imap_password' : 'access_token') }).id('account-token').type(InputType.Password)
            .enableAutoFill(false).onChange((value) => { this.token = value; this.candidates = []; }).enabled(!this.busy).height(52)
          if (this.smtpEndpoint !== '' && this.protocol === 'imap') {
            Text(this.label('discovery_outgoing')).fontWeight(FontWeight.Medium).width('100%')
            Text(this.smtpEndpoint).fontSize(14).width('100%')
            TextInput({ text: this.smtpUsername, placeholder: this.label('smtp_username') }).id('account-smtp-username')
              .enableAutoFill(false).enabled(!this.busy).onChange(value => this.smtpUsername = value).height(52)
            Row({ space: 12 }) {
              Text(this.label('discovery_same_password')).fontSize(14).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.smtpSamePassword }).id('account-smtp-same-password')
                .enabled(!this.busy).onChange(value => this.smtpSamePassword = value)
            }.width('100%')
            Text(this.label('discovery_smtp_edit')).fontSize(13).fontColor($r('app.color.mail_text_secondary')).width('100%')
          }
          Button(this.label('connect_account')).id('connect-account').width('100%')
            .enabled(this.ready && !this.busy && this.serverUrl.trim().length > 0 && this.token.length > 0 &&
              (this.protocol === 'jmap' || (this.username.trim().length > 0 && this.emailAddress.trim().length > 0)))
            .onClick(() => this.probe())
          ForEach(this.candidates, (candidate: JmapAccount) => {
            Button(candidate.name).width('100%').enabled(!this.busy).onClick(() => this.saveAccount(candidate))
          }, (candidate: JmapAccount) => candidate.id)
          if (!this.ready && !this.busy) { Button(this.label('retry')).onClick(() => this.initialize()) }
          Text(this.label(this.protocol === 'imap' ? 'imap_connected_features' : 'connected_features'))
            .fontSize(13).fontColor($r('app.color.mail_text_secondary')).width('100%')
        }.padding(20).width('100%').constraintSize({ maxWidth: 640 })
      }.width('100%').height('100%').align(Alignment.Top)
  }

  @Builder
  private inboxMenus() {
    if (this.openInboxOnLaunch && this.accounts.length > 0) {
      Row({ space: this.compact ? 12 : 16 }) {
        Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(24).fontColor([$r('app.color.mail_text_primary')]) }
          .id('compose-mail').width(44).height(44).backgroundColor($r('app.color.mail_surface'))
          .accessibilityText(this.label('compose')).enabled(this.account.emailAddress !== '')
          .onClick(() => this.paths.pushPathByName('compose', null))
        Button({ type: ButtonType.Circle }) { SymbolGlyph($r('sys.symbol.folder')).fontSize(24).fontColor([$r('app.color.mail_text_primary')]) }
          .width(44).height(44).backgroundColor($r('app.color.mail_surface'))
          .id('open-mailboxes').accessibilityText(this.label('mailboxes')).enabled(this.account.id !== '')
          .onClick(() => this.paths.pushPathByName('boxes', null))

      }.id('inbox-actions')
    }
  }

  @Builder
  private inboxTitle() {
    Row({ space: this.compact ? 12 : 16 }) {
      Text(this.openInboxOnLaunch && this.accounts.length > 0 ?
        this.currentMailboxTitle() : this.label('accounts'))
        .id('inbox-title').fontSize(this.openInboxOnLaunch ? this.compact ? 26 : 36 : 20)
        .lineHeight(this.openInboxOnLaunch ? this.compact ? 30 : 41.4 : 24).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.mail_text_primary')).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      this.inboxMenus()
    }.width('100%').height('100%').padding({ left: this.compact ? 16 : 20, right: this.compact ? 16 : 20,
      top: this.compact ? 8 : this.tablet ? 24 : 18, bottom: this.compact ? 4 : this.tablet ? 16 : 12 })
  }

  private currentMailboxTitle(): string {
    const selected = this.boxes.find(box => box.id === this.mailboxId);
    return selected ? this.boxLabel(selected) : this.boxName || this.label('inbox');
  }

  build() {
    Navigation(this.paths) {
      if (!this.ready) {
        Column() {
          this.status()
          if (!this.busy) { Button(this.label('retry')).onClick(() => this.initialize()) }
        }.width('100%').height('100%')
      } else if (this.openInboxOnLaunch && this.accounts.length > 0) {
        this.messageList()
      } else {
        this.accountForm()
      }
    }.title({ builder: this.inboxTitle, height: this.compact ? 56 : this.tablet ? 84 : 74 })
    .onAreaChange((_, area) => { this.compact = Number(area.height) < 500 || Number(area.width) < 360; this.tablet = Number(area.width) >= 760; })
    .titleMode(NavigationTitleMode.Mini).navDestination(this.destinations)
    .onNavBarStateChange((visible: boolean) => { if (this.openInboxOnLaunch) { this.inboxVisibilityChanged(visible); } })
    .hideBackButton(this.openInboxOnLaunch)
    .mode(this.openInboxOnLaunch ? NavigationMode.Auto : NavigationMode.Stack)
    .navBarWidth('40%').navBarWidthRange([320, 480]).minContentWidth(360)
    .backgroundColor($r('app.color.mail_background'))
  }
}
