// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { validateEmailAddress } from 'libthunderbird.so';
import { BusinessError } from '@kit.BasicServicesKit';
import { JmapAccount, JmapCredentials, JmapError, JmapEmail } from '../mail/jmap/JmapClient';
import { SmtpSettings, OutgoingDraft } from '../mail/smtp/NativeSmtpClient';
import { OutgoingAttachmentFiles } from '../mail/attachments/OutgoingAttachmentFiles';
import { OutgoingAttachment, SmtpAttachmentData, outgoingAttachmentsOwned, outgoingAccountValid, outgoingUUIDValid } from '../mail/attachments/OutgoingAttachmentModel';
import { MailCache } from './MailCache';
import { MailContentFiles } from './MailContentFiles';
import { CachedEmail, cacheIsFresh } from './MailCacheModel';
import { PictureCache } from './PictureCache';
import { PreparedDocumentStore } from './PreparedDocumentStore';
import { MailSyncStore } from './MailSyncStore';
import { RecipientStore } from './RecipientStore';
import { RecipientRecord, RecipientFields, sentRecipients, cachedSentRecipients, knownRecipientNames } from './RecipientHistory';
import { CompositionSettings, normalizeComposition, applyComposition } from './CompositionSettings';
import { MathSettings, normalizeMathSettings } from './MathSettings';
import { NotificationStore } from './NotificationStore';
import { UnreadBadgeStore } from './UnreadBadgeStore';
import { NotificationAccountState } from '../mail/notifications/NotificationModel';
import { AttachmentFiles } from '../mail/attachments/AttachmentFiles';
import { OAuthSecretBox, OAuthSecretSession } from './OAuthSecretBox';
import { NativeBrowserOAuth, BrowserOAuthError } from '../mail/oauth/NativeBrowserOAuth';
import { SavedOAuthLogin, RegisteredMailOAuth } from '../mail/oauth/RegisteredMailOAuth';

export class SavedAccount {
  id: string = '';
  serverId: string = '';
  name: string = '';
  sessionUrl: string = '';
  emailAddress: string = '';
  authentication: string = '';
  username: string = '';
}

// Callers retain their own missing-secret policy and clear the returned buffer.
async function storedSecret(alias: string): Promise<Uint8Array | undefined> {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  const results = await asset.query(query);
  return results[0]?.get(asset.Tag.SECRET) as Uint8Array | undefined;
}

class OAuthCredentials implements JmapCredentials {
  username: string;
  private store: AccountStore;
  private account: SavedAccount;
  private background: boolean;
  constructor(store: AccountStore, account: SavedAccount, background: boolean = false) { this.store = store; this.account = account; this.username = account.username; this.background = background; }
  async authorization(): Promise<string> { return `Bearer ${await this.store.oauthAccessToken(this.account, undefined, this.background)}`; }
}

class StoredCredentials implements JmapCredentials {
  private alias: string;
  private scheme: string;
  private store?: AccountStore;
  private accountId: string;
  constructor(alias: string, scheme: string, store?: AccountStore, accountId: string = '') { this.alias = alias; this.scheme = scheme; this.store = store; this.accountId = accountId; }
  async authorization(): Promise<string> {
    if (this.store && !(await this.store.notificationSettings(this.accountId)).enabled) { throw new JmapError('authenticationRequired'); }
    try {
      const secret = await storedSecret(this.alias);
      if (!secret) { throw new Error(); }
      try { return `${this.scheme} ${new util.TextDecoder().decodeToString(secret)}`; }
      finally { secret.fill(0); }
    } catch (_) { throw new JmapError('authenticationRequired'); }
  }
}

// Metadata and secrets use separate stores. Pending/deleting rows make cleanup
// recoverable if a process stops between the RDB and Asset Store operations.
export class AccountStore {
  private db?: relationalStore.RdbStore;
  private pending: Promise<void> = Promise.resolve();
  private opening?: Promise<void>;
  private closing?: Promise<void>;
  private databaseRevision: number = 0;
  private name: string;
  private mailCache?: MailCache;
  private pictureCache?: PictureCache;
  private preparedDocuments?: PreparedDocumentStore;
  private mailSyncData?: MailSyncStore;
  private recipientStore?: RecipientStore;
  private notificationData?: NotificationStore;
  private unreadBadges?: UnreadBadgeStore;
  private notificationChanges: Promise<void> = Promise.resolve();
  private mailSyncTasks: Set<Promise<void>> = new Set();
  private cacheDir: string = '';
  private filesDir: string = '';
  private outgoingFiles?: OutgoingAttachmentFiles;
  private contentFiles?: MailContentFiles;
  private refreshing: Map<string, Promise<string>> = new Map();
  oauthService: NativeBrowserOAuth = new NativeBrowserOAuth();
  constructor(name: string = 'thunderbird_accounts.db') { this.name = name; }

  async open(context: common.Context): Promise<void> {
    while (this.closing) { await this.closing; }
    if (this.db && !this.opening) { return; }
    if (!this.opening) { this.opening = this.initialize(context); }
    try { await this.opening; }
    finally { this.opening = undefined; }
  }

  async openForMailChecks(context: common.Context): Promise<void> {
    while (this.closing) { await this.closing; }
    if (this.db && !this.opening) { return; }
    if (!this.opening) { this.opening = this.initializeForMailChecks(context); }
    try { await this.opening; }
    finally { this.opening = undefined; }
  }

  private async initializeForMailChecks(context: common.Context): Promise<void> {
    ++this.databaseRevision;
    this.contentFiles = new MailContentFiles(context.filesDir);
    try {
      this.db = await relationalStore.getRdbStore(context, { name: this.name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
      if (this.db.version !== 5) { throw new Error('Account storage is not initialized'); }
      // Background work may share the DB with account setup. Never migrate,
      // prune message/picture caches or remove a pending foreground account.
      const rows = await this.db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('accounts', 'oauth_credentials', 'mail_notifications', 'mail_check_lease', 'oauth_refresh_lease')");
      let tables = 0;
      try { while (rows.goToNextRow()) { tables++; } } finally { rows.close(); }
      if (tables !== 5) { throw new Error('Mail checking is not initialized'); }
      this.notificationData = new NotificationStore(this.db, this.databaseQueue(this.db));
      const badgeTable = await this.db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'mail_unread_badges'");
      let badgesAvailable = false;
      try { badgesAvailable = badgeTable.goToFirstRow(); } finally { badgeTable.close(); }
      this.unreadBadges = new UnreadBadgeStore(this.db, this.databaseQueue(this.db), badgesAvailable);
      // Attach only caches already created by a foreground open. Background
      // checking must never migrate or prune the user's saved mail.
      const cacheTables = await this.db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('mail_cache', 'picture_cache', 'picture_consent', 'picture_snapshot', 'prepared_documents', 'mail_sync_jobs', 'mail_sync_cursors')");
      const available = new Set<string>();
      try { while (cacheTables.goToNextRow()) { available.add(cacheTables.getString(0)); } } finally { cacheTables.close(); }
      const queue = this.databaseQueue(this.db);
      if (available.has('mail_cache')) { this.mailCache = new MailCache(this.db, queue, this.unreadBadges, this.contentFiles); }
      if (available.has('picture_cache') && available.has('picture_consent') && available.has('picture_snapshot')) {
        this.pictureCache = new PictureCache(this.db, queue);
      }
      if (available.has('prepared_documents')) { this.preparedDocuments = new PreparedDocumentStore(this.db, queue, this.contentFiles); }
      if (available.has('mail_sync_jobs') && available.has('mail_sync_cursors')) { this.mailSyncData = new MailSyncStore(this.db, queue); }
    } catch (_) {
      try { this.db?.close(); } catch (_) {}
      this.db = undefined; throw new Error('Mail checking storage is unavailable');
    }
  }

  private async initialize(context: common.Context): Promise<void> {
    ++this.databaseRevision;
    this.cacheDir = context.cacheDir;
    this.filesDir = context.filesDir;
    this.outgoingFiles = new OutgoingAttachmentFiles(context.filesDir);
    this.contentFiles = new MailContentFiles(context.filesDir);
    try {
      this.db = await relationalStore.getRdbStore(context, {
        name: this.name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
      });
      if (this.db.version > 5) { throw new Error('Unsupported schema'); }
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, server_id TEXT NOT NULL, name TEXT NOT NULL, session_url TEXT NOT NULL, status TEXT NOT NULL)');
      // Inspect the column so migration is safe if a process stops after
      // ALTER TABLE but before the schema version is updated.
      const columns = await this.db.querySql('PRAGMA table_info(accounts)');
      let hasEmailAddress = false;
      let hasAuthentication = false; let hasUsername = false;
      try { while (columns.goToNextRow()) {
        const name = columns.getString(columns.getColumnIndex('name'));
        if (name === 'email_address') { hasEmailAddress = true; }
        if (name === 'authentication') { hasAuthentication = true; }
        if (name === 'username') { hasUsername = true; }
      } }
      finally { columns.close(); }
      if (!hasEmailAddress) { await this.db.executeSql("ALTER TABLE accounts ADD COLUMN email_address TEXT NOT NULL DEFAULT ''"); }
      if (!hasAuthentication) { await this.db.executeSql("ALTER TABLE accounts ADD COLUMN authentication TEXT NOT NULL DEFAULT ''"); }
      if (!hasUsername) { await this.db.executeSql("ALTER TABLE accounts ADD COLUMN username TEXT NOT NULL DEFAULT ''"); }
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS oauth_credentials (account_id TEXT PRIMARY KEY, envelope TEXT NOT NULL)');
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS oauth_refresh_lease (account_id TEXT PRIMARY KEY, owner TEXT NOT NULL, expires INTEGER NOT NULL)');
      await NotificationStore.initialize(this.db);
      await UnreadBadgeStore.initialize(this.db);
      await MailCache.initialize(this.db, this.contentFiles);
      await PictureCache.initialize(this.db);
      await PreparedDocumentStore.initialize(this.db);
      await MailSyncStore.initialize(this.db);
      await RecipientStore.initialize(this.db);
      await this.db.executeSql("CREATE TABLE IF NOT EXISTS account_mail_actions (account_id TEXT PRIMARY KEY, action TEXT NOT NULL)");
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS account_composition (account_id TEXT PRIMARY KEY, sender_name TEXT NOT NULL, signature TEXT NOT NULL)');
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS account_math (account_id TEXT PRIMARY KEY, render_reading INTEGER NOT NULL, send_format TEXT NOT NULL)');
      const mathColumns = await this.db.querySql('PRAGMA table_info(account_math)');
      let hasMathRenderer = false;
      try {
        if (mathColumns.goToFirstRow()) {
          do { if (mathColumns.getString(1) === 'renderer') { hasMathRenderer = true; } } while (mathColumns.goToNextRow());
        }
      } finally { mathColumns.close(); }
      if (!hasMathRenderer) { await this.db.executeSql("ALTER TABLE account_math ADD COLUMN renderer TEXT NOT NULL DEFAULT 'mathml'"); }
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS outgoing_drafts (account_id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
      // Additive UI metadata remains compatible with the version-five account
      // schema. Keep the selection inside this encrypted, per-store database.
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS account_preferences (name TEXT PRIMARY KEY, account_id TEXT NOT NULL)');
      this.db.version = 5;
      const queue = this.databaseQueue(this.db);
      this.unreadBadges = new UnreadBadgeStore(this.db, queue);
      this.mailCache = new MailCache(this.db, queue, this.unreadBadges, this.contentFiles);
      this.pictureCache = new PictureCache(this.db, queue);
      this.preparedDocuments = new PreparedDocumentStore(this.db, queue, this.contentFiles);
      this.mailSyncData = new MailSyncStore(this.db, queue);
      this.recipientStore = new RecipientStore(this.db, queue);
      this.notificationData = new NotificationStore(this.db, queue);
      const interrupted = await this.rows("SELECT * FROM accounts WHERE status != 'ready'");
      for (const account of interrupted) { await this.remove(account.id); }
      await this.contentFiles.prune().catch(() => {});
      await this.pruneOutgoingFiles().catch(() => {});
    } catch (error) {
      try { this.db?.close(); } catch (_) {}
      this.db = undefined;
      throw new Error(`Account storage is unavailable (${(error as BusinessError).code})`);
    }
  }

  private database(): relationalStore.RdbStore {
    if (!this.db) { throw new Error('Account storage is unavailable'); }
    return this.db;
  }

  private alias(id: string): string { return `tb.jmap.${this.name}.${id}`; }

  credentials(account: SavedAccount, background: boolean = false): JmapCredentials {
    if (account.authentication === 'oauth') { return new OAuthCredentials(this, account, background); }
    return new StoredCredentials(`${this.alias(account.id)}${background ? '.background' : ''}`, account.sessionUrl.startsWith('imaps://') ? 'Basic' : 'Bearer', background ? this : undefined, account.id);
  }

  get notifications(): NotificationStore {
    if (!this.notificationData || !this.db) { throw new Error('Mail checking storage is unavailable'); }
    return this.notificationData;
  }

  get badges(): UnreadBadgeStore {
    if (!this.unreadBadges || !this.db) { throw new Error('Unread badge storage is unavailable'); }
    return this.unreadBadges;
  }

  notificationSettings(accountId: string): Promise<NotificationAccountState> { return this.notifications.get(accountId); }

  setNotificationFrequencies(accountId: string, foreground: number, background: number): Promise<void> {
    return this.notifications.frequencies(accountId, foreground, background);
  }

  setNotifications(accountId: string, enabled: boolean): Promise<void> {
    const task = this.notificationChanges.catch(() => {}).then(async () => {
      if (!enabled) {
        // Stop scheduling/notifying first, then revoke only the opted-in copy.
        await this.notifications.configure(accountId, false);
        await this.revokeBackgroundAccess(accountId);
        return;
      }
      const account = (await this.list()).find(value => value.id === accountId);
      if (!account) { throw new Error('Account is unavailable'); }
      const alias = account.authentication === 'oauth' ? this.oauthAlias(accountId) : this.alias(accountId);
      await this.copyBackgroundAccess(alias);
      try {
        await this.notifications.configure(accountId, true);
        if (!(await this.notificationSettings(accountId)).enabled) { throw new Error('Account is unavailable'); }
      } catch (error) { await this.revokeBackgroundAccess(accountId); throw error as Error; }
    });
    this.notificationChanges = task.catch(() => {});
    return task;
  }

  private async copyBackgroundAccess(alias: string): Promise<void> {
    const bytes = await storedSecret(alias);
    if (!bytes) { throw new Error('Credential storage unavailable'); }
    try {
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(`${alias}.background`));
      attributes.set(asset.Tag.SECRET, bytes);
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
      await asset.add(attributes);
    } finally { bytes.fill(0); }
  }

  private async revokeBackgroundAccess(accountId: string): Promise<void> {
    await OAuthSecretBox.remove(`${this.alias(accountId)}.background`);
    await OAuthSecretBox.remove(`${this.oauthAlias(accountId)}.background`);
  }

  get mail(): MailCache {
    if (!this.mailCache || !this.db) { throw new Error('Account storage is unavailable'); }
    return this.mailCache;
  }

  get pictures(): PictureCache {
    if (!this.pictureCache || !this.db) { throw new Error('Account storage is unavailable'); }
    return this.pictureCache;
  }

  get documents(): PreparedDocumentStore {
    if (!this.preparedDocuments || !this.db) { throw new Error('Prepared document storage is unavailable'); }
    return this.preparedDocuments;
  }

  get mailSyncAvailable(): boolean {
    return this.db !== undefined && this.mailCache !== undefined && this.pictureCache !== undefined && this.preparedDocuments !== undefined && this.mailSyncData !== undefined;
  }

  get sync(): MailSyncStore {
    if (!this.mailSyncData || !this.db) { throw new Error('Mail sync storage is unavailable'); }
    return this.mailSyncData;
  }

  trackMailSync(task: Promise<void>): void {
    this.mailSyncTasks.add(task);
    task.then(() => this.mailSyncTasks.delete(task), () => this.mailSyncTasks.delete(task));
  }

  private async rows(sql: string): Promise<SavedAccount[]> {
    let result: relationalStore.ResultSet;
    try { result = await this.database().querySql(sql); }
    catch (_) { throw new Error('Account data could not be read'); }
    const accounts: SavedAccount[] = [];
    try {
      while (result.goToNextRow()) {
        const account = new SavedAccount();
        account.id = result.getString(result.getColumnIndex('id'));
        account.serverId = result.getString(result.getColumnIndex('server_id'));
        account.name = result.getString(result.getColumnIndex('name'));
        account.sessionUrl = result.getString(result.getColumnIndex('session_url'));
        account.emailAddress = result.getString(result.getColumnIndex('email_address'));
        account.authentication = result.getString(result.getColumnIndex('authentication'));
        account.username = result.getString(result.getColumnIndex('username'));
        accounts.push(account);
      }
    } catch (_) { throw new Error('Account data could not be read'); }
    finally { try { result.close(); } catch (_) {} }
    return accounts;
  }

  async list(): Promise<SavedAccount[]> {
    let accounts: SavedAccount[] = [];
    await this.enqueue(async () => { accounts = await this.rows("SELECT * FROM accounts WHERE status = 'ready' ORDER BY name, id"); });
    return accounts;
  }

  async lastVisitedAccount(): Promise<SavedAccount | null> {
    let accounts: SavedAccount[] = [];
    await this.enqueue(async () => {
      accounts = await this.rows("SELECT a.* FROM accounts a JOIN account_preferences p ON p.account_id = a.id WHERE p.name = 'last_visited' AND a.status = 'ready'");
    });
    // Missing, deleted, or interrupted accounts cannot become the launch target.
    return accounts[0] ?? null;
  }

  rememberVisitedAccount(id: string): Promise<void> {
    return this.enqueue(async () => {
      // Validate and write in one statement. A late UI selection must not
      // resurrect a removed account or replace a valid preference with a stale ID.
      await this.database().executeSql("INSERT OR REPLACE INTO account_preferences (name, account_id) SELECT 'last_visited', id FROM accounts WHERE id = ? AND status = 'ready'", [id]);
    });
  }

  private databaseQueue(db: relationalStore.RdbStore): (operation: () => Promise<void>) => Promise<void> {
    const revision = this.databaseRevision;
    return operation => this.enqueue(operation, db, revision);
  }

  private enqueue(operation: () => Promise<void>, db: relationalStore.RdbStore | undefined = this.db, revision: number = this.databaseRevision): Promise<void> {
    const task = this.pending.catch(() => {}).then(async () => {
      if (!db || this.db !== db || revision !== this.databaseRevision) { throw new Error('Account storage is unavailable'); }
      await operation();
    });
    this.pending = task.catch(() => {});
    return task;
  }

  async add(sessionUrl: string, server: JmapAccount, token: string, emailAddress: string = '', smtp?: SmtpSettings, oauth?: SavedOAuthLogin): Promise<SavedAccount> {
    const identity = emailAddress.trim();
    if (identity.length > 512 || (identity !== '' && !validateEmailAddress(identity))) { throw new Error('Invalid email address'); }
    const secret = token === '' ? new Uint8Array(0) : new util.TextEncoder().encodeInto(token);
    if (oauth ? (!RegisteredMailOAuth.valid(oauth) || sessionUrl !== RegisteredMailOAuth.incoming(oauth.registration.provider)) :
      (!/^[A-Za-z0-9._~+\/-]+=*$/.test(token) || secret.length > (sessionUrl.startsWith('imaps://') ? 4090 : 1024))) {
      secret.fill(0);
      throw new Error('Invalid account token');
    }
    const account = new SavedAccount();
    account.id = util.generateRandomUUID(); account.serverId = server.id;
    account.name = identity || server.name; account.sessionUrl = sessionUrl; account.emailAddress = identity;
    account.authentication = oauth ? 'oauth' : ''; account.username = oauth?.username ?? '';
    try {
      await this.enqueue(async () => {
        await this.database().executeSql('INSERT INTO accounts (id, server_id, name, session_url, status, email_address, authentication, username) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [account.id, account.serverId, account.name, account.sessionUrl, 'pending', account.emailAddress, account.authentication, account.username]);
        if (oauth) {
          const envelope = await OAuthSecretBox.create(this.oauthAlias(account.id), JSON.stringify(oauth));
          await this.database().executeSql('INSERT INTO oauth_credentials (account_id, envelope) VALUES (?, ?)', [account.id, envelope]);
        } else {
        const attributes: asset.AssetMap = new Map();
        attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.alias(account.id)));
        attributes.set(asset.Tag.SECRET, secret);
        attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
        attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
        // Omit IS_PERSISTENT: the default removes the asset on uninstall.
        // Setting the tag itself requires a separate persistent-data permission.
        await asset.add(attributes);
        }
        if (smtp) {
          const outgoing = new util.TextEncoder().encodeInto(JSON.stringify(smtp));
          try {
            if (outgoing.length > 4096) { throw new Error('Outgoing settings are too long'); }
            const smtpAttributes: asset.AssetMap = new Map();
            smtpAttributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.smtpAlias(account.id)));
            smtpAttributes.set(asset.Tag.SECRET, outgoing);
            smtpAttributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
            smtpAttributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
            await asset.add(smtpAttributes);
          } finally { outgoing.fill(0); }
        }
        await this.database().executeSql("UPDATE accounts SET status = 'ready' WHERE id = ?", [account.id]);
      });
      return account;
    } catch (error) {
      // The row remains discoverable for recovery if immediate cleanup fails.
      try { await this.remove(account.id); } catch (_) {}
      throw new Error(`Account could not be saved (${(error as BusinessError).code})`);
    } finally { secret.fill(0); }
  }

  private smtpAlias(id: string): string { return `tb.smtp.${this.name}.${id}`; }
  private oauthAlias(id: string): string { return `tb.oauth.${this.name}.${id}`; }

  async replaceOAuth(account: SavedAccount, server: JmapAccount, login: SavedOAuthLogin): Promise<void> {
    if (account.authentication !== 'oauth' || !RegisteredMailOAuth.valid(login) ||
      login.username !== account.username || server.id !== account.serverId ||
      account.sessionUrl !== RegisteredMailOAuth.incoming(login.registration.provider) ||
      login.tokens.expiresAt <= Date.now() / 1000 + 60) { throw new JmapError('authenticationRequired'); }
    await this.enqueue(async () => {
      const current = (await this.rows("SELECT * FROM accounts WHERE status = 'ready'")).find(value => value.id === account.id);
      if (!current || current.authentication !== 'oauth' || current.serverId !== account.serverId ||
        current.sessionUrl !== account.sessionUrl || current.username !== account.username ||
        current.emailAddress !== account.emailAddress) { throw new JmapError('authenticationRequired'); }
      // Keep the same encryption key and account ID. Cache, drafts, outgoing
      // settings and an already-enabled background alias remain intact.
      const next = await OAuthSecretBox.seal(this.oauthAlias(account.id), JSON.stringify(login));
      await this.database().executeSql("UPDATE oauth_credentials SET envelope = ? WHERE account_id = ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready' AND authentication = 'oauth' AND server_id = ? AND session_url = ? AND username = ? AND email_address = ?)",
        [next, account.id, account.id, account.serverId, account.sessionUrl, account.username, account.emailAddress]);
      if (await this.oauthEnvelope(account) !== next) { throw new JmapError('authenticationRequired'); }
      // An older refresh still owns its lease until it finishes. Its existing
      // envelope comparison prevents it from overwriting this new sign-in.
    });
  }

  private async oauthEnvelope(account: SavedAccount): Promise<string> {
    const result = await this.database().querySql("SELECT o.envelope FROM oauth_credentials o JOIN accounts a ON a.id = o.account_id WHERE a.id = ? AND a.status = 'ready' AND a.authentication = 'oauth'", [account.id]);
    try { if (!result.goToFirstRow()) { throw new JmapError('authenticationRequired'); } return result.getString(0); }
    finally { result.close(); }
  }

  oauthAccessToken(account: SavedAccount, smtp?: SmtpSettings, background: boolean = false): Promise<string> {
    if (account.authentication !== 'oauth') { return Promise.reject(new JmapError('authenticationRequired')); }
    if (background && smtp) { return Promise.reject(new JmapError('authenticationRequired')); }
    // Validate the outgoing destination before sharing a token with its caller.
    return this.oauthTokenForEndpoint(account, smtp, background);
  }

  private async oauthTokenForEndpoint(account: SavedAccount, smtp?: SmtpSettings, background: boolean = false): Promise<string> {
    await this.pending;
    if (background && !(await this.notificationSettings(account.id)).enabled) { throw new JmapError('authenticationRequired'); }
    const envelope = await this.oauthEnvelope(account);
    const login = JSON.parse(await OAuthSecretBox.open(this.oauthAlias(account.id), envelope, background)) as SavedOAuthLogin;
    if (!RegisteredMailOAuth.valid(login) || login.username !== account.username ||
      account.sessionUrl !== RegisteredMailOAuth.incoming(login.registration.provider) ||
      (smtp && (!RegisteredMailOAuth.allowsOutgoing(login.registration.provider, smtp.endpoint) || smtp.username !== login.username))) {
      throw new JmapError('authenticationRequired');
    }
    if (login.tokens.expiresAt > Date.now() / 1000 + 60) { return login.tokens.accessToken; }
    const existing = this.refreshing.get(account.id);
    if (existing) { return existing; }
    const refresh = this.refreshOAuth(account, login, envelope, background);
    this.refreshing.set(account.id, refresh);
    try { return await refresh; }
    finally { if (this.refreshing.get(account.id) === refresh) { this.refreshing.delete(account.id); } }
  }

  private async acquireRefreshLease(accountId: string, owner: string): Promise<boolean> {
    const now = Date.now();
    let acquired = false;
    await this.enqueue(async () => {
      const db = this.database(); db.beginTransaction();
      try {
        await db.executeSql("INSERT OR IGNORE INTO oauth_refresh_lease (account_id, owner, expires) SELECT id, '', 0 FROM accounts WHERE id = ? AND status = 'ready' AND authentication = 'oauth'", [accountId]);
        // The native token request has a 15-second bound. Leave enough time to
        // persist its result; a crashed process cannot retain ownership forever.
        await db.executeSql("UPDATE oauth_refresh_lease SET owner = ?, expires = ? WHERE account_id = ? AND (expires <= ? OR expires > ?) AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
          [owner, now + 60000, accountId, now, now + 120000, accountId]);
        db.commit();
      } catch (error) { db.rollBack(); throw error as Error; }
      // A pooled reader cannot see the uncommitted lease write. Keep its
      // ownership check outside the transaction and rollback handler.
      const rows = await db.querySql('SELECT owner FROM oauth_refresh_lease WHERE account_id = ?', [accountId]);
      try { acquired = rows.goToFirstRow() && rows.getString(0) === owner; } finally { rows.close(); }
    });
    return acquired;
  }

  private releaseRefreshLease(accountId: string, owner: string): Promise<void> {
    return this.enqueue(() => this.database().executeSql('DELETE FROM oauth_refresh_lease WHERE account_id = ? AND owner = ?', [accountId, owner]));
  }

  private async refreshOAuth(account: SavedAccount, login: SavedOAuthLogin, previous: string, background: boolean = false): Promise<string> {
    const owner = util.generateRandomUUID();
    let acquired = false;
    let key: OAuthSecretSession | undefined;
    try {
      // Retain the original AES key across the request. Revoking a background
      // alias stops later work but must not discard an accepted token rotation.
      key = await OAuthSecretBox.retain(this.oauthAlias(account.id), background);
      acquired = await this.acquireRefreshLease(account.id, owner);
      const deadline = Date.now() + 20000;
      for (let attempt = 0; ; attempt++) {
        if (background && !(await this.notificationSettings(account.id)).enabled) { throw new JmapError('network'); }
        const current = await this.oauthEnvelope(account);
        const newest = JSON.parse(await key.open(current)) as SavedOAuthLogin;
        if (!RegisteredMailOAuth.valid(newest) || newest.username !== account.username ||
          newest.registration.provider !== login.registration.provider || account.sessionUrl !== RegisteredMailOAuth.incoming(newest.registration.provider)) {
          throw new JmapError('authenticationRequired');
        }
        if (newest.tokens.expiresAt > Date.now() / 1000 + 60) { return newest.tokens.accessToken; }
        if (acquired) { login = newest; previous = current; break; }
        // An inbox check can be rotating this account's token while Send starts.
        // Reuse its persisted result; never race the owner or retry its request.
        // Count bounds the wait even if the wall clock moves backwards.
        if (attempt >= 40 || Date.now() >= deadline) { throw new JmapError('network'); }
        await new Promise<void>(resolve => { setTimeout(resolve, 500); });
      }
      if (!login.tokens.refreshToken) { throw new JmapError('authenticationRequired'); }
      login.tokens = await this.oauthService.refresh(login.registration, login.tokens.refreshToken);
      if (!RegisteredMailOAuth.valid(login) || login.tokens.expiresAt <= Date.now() / 1000 + 60) { throw new JmapError('authenticationRequired'); }
      const next = await key.seal(JSON.stringify(login));
      await this.enqueue(async () => {
        // Removal or another credential write wins over a late network reply.
        if (await this.oauthEnvelope(account) !== previous) { throw new JmapError('authenticationRequired'); }
        await this.database().executeSql("UPDATE oauth_credentials SET envelope = ? WHERE account_id = ? AND envelope = ? AND EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [next, account.id, previous, account.id]);
        if (await this.oauthEnvelope(account) !== next) { throw new JmapError('authenticationRequired'); }
      });
      return login.tokens.accessToken;
    } catch (error) {
      throw new JmapError((error as BrowserOAuthError).code === 'network' ? 'network' : 'authenticationRequired');
    } finally {
      key?.close();
      if (acquired) { await this.releaseRefreshLease(account.id, owner).catch(() => {}); }
    }
  }

  async smtp(account: SavedAccount): Promise<SmtpSettings> {
    await this.pending;
    try {
      const secret = await storedSecret(this.smtpAlias(account.id));
      if (!secret) { return new SmtpSettings(); }
      try { return JSON.parse(new util.TextDecoder().decodeToString(secret)) as SmtpSettings; }
      finally { secret.fill(0); }
    } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) { return new SmtpSettings(); }
      throw new Error('Outgoing settings are unavailable');
    }
  }

  async saveSmtp(account: SavedAccount, settings: SmtpSettings): Promise<void> {
    if (account.authentication === 'oauth') {
      // Saving settings is local: validate the provider binding without
      // renewing a token or contacting the SMTP server.
      await this.pending;
      const login = JSON.parse(await OAuthSecretBox.open(this.oauthAlias(account.id), await this.oauthEnvelope(account))) as SavedOAuthLogin;
      if (!RegisteredMailOAuth.valid(login) || login.username !== account.username ||
        account.sessionUrl !== RegisteredMailOAuth.incoming(login.registration.provider)) {
        throw new JmapError('authenticationRequired');
      }
      if (!RegisteredMailOAuth.allowsOutgoing(login.registration.provider, settings.endpoint) || settings.username !== login.username) {
        throw new JmapError('unsafeEndpoint');
      }
    }
    const secret = new util.TextEncoder().encodeInto(JSON.stringify(settings));
    if (secret.length > 4096) { secret.fill(0); throw new Error('Outgoing settings are too long'); }
    try {
      await this.enqueue(async () => {
        const ready = await this.database().querySql("SELECT 1 FROM accounts WHERE id = ? AND status = 'ready'", [account.id]);
        try { if (!ready.goToFirstRow()) { throw new Error('Account is unavailable'); } }
        finally { ready.close(); }
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.smtpAlias(account.id)));
        const update: asset.AssetMap = new Map(); update.set(asset.Tag.SECRET, secret);
        try { await asset.update(query, update); }
        catch (error) {
          if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw new Error('Outgoing credentials could not be updated'); }
          query.set(asset.Tag.SECRET, secret);
          query.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
          query.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
          await asset.add(query);
        }
      });
    } finally { secret.fill(0); }
  }

  async outgoing(accountId: string, sendingActive: boolean = false): Promise<OutgoingDraft | null> {
    let draft: OutgoingDraft | null = null;
    await this.enqueue(async () => {
      const result = await this.database().querySql('SELECT payload FROM outgoing_drafts WHERE account_id = ?', [accountId]);
      try {
        if (!result.goToFirstRow()) { return; }
        draft = JSON.parse(result.getString(0)) as OutgoingDraft;
        if (draft.attachments !== undefined && (!Array.isArray(draft.attachments) ||
          (draft.attachments.length > 0 && !outgoingAttachmentsOwned(accountId, draft.id, draft.attachments)))) {
          throw new Error('Invalid draft attachments');
        }
        draft.attachments = draft.attachments ?? [];
        // A process may have stopped after DATA was accepted but before storage.
        if (draft.state === 'sending' && !sendingActive) { draft.state = 'unconfirmed'; }
      } finally { result.close(); }
    });
    return draft;
  }

  async recipients(accountId: string): Promise<RecipientRecord[]> {
    const history = this.recipientStore;
    if (!history) { return []; }
    // Upgrade from downloaded, explicitly identified Sent mail only. Drafts,
    // the incoming address book, and failed submissions cannot seed history.
    const messages: CachedEmail[] = await this.mail.cachedMessages(accountId, false).catch((): CachedEmail[] => []);
    const boxes = await this.mail.boxes(accountId).catch(() => null);
    await history.remember(accountId, cachedSentRecipients(messages.map((record: CachedEmail): JmapEmail => record.mail), boxes?.boxes || []));
    return history.list(accountId);
  }

  async mailAction(accountId: string): Promise<string> {
    let action = 'archive';
    await this.enqueue(async () => {
      const rows = await this.database().querySql("SELECT c.action FROM account_mail_actions c JOIN accounts a ON a.id = c.account_id WHERE c.account_id = ? AND a.status = 'ready'", [accountId]);
      try { if (rows.goToFirstRow() && rows.getString(0) === 'delete') { action = 'delete'; } }
      finally { rows.close(); }
    });
    return action;
  }
  saveMailAction(accountId: string, action: string): Promise<void> {
    if (action !== 'archive' && action !== 'delete') { return Promise.reject(new Error('Invalid mail action')); }
    return this.enqueue(async () => {
      await this.database().executeSql("INSERT OR REPLACE INTO account_mail_actions (account_id, action) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [accountId, action, accountId]);
    });
  }

  async composition(accountId: string): Promise<CompositionSettings> {
    let settings = new CompositionSettings();
    await this.enqueue(async () => {
      const rows = await this.database().querySql("SELECT c.sender_name, c.signature FROM account_composition c JOIN accounts a ON a.id = c.account_id WHERE c.account_id = ? AND a.status = 'ready'", [accountId]);
      try {
        if (rows.goToFirstRow()) { settings = normalizeComposition({ senderName: rows.getString(0), signature: rows.getString(1) }); }
      } finally { rows.close(); }
    });
    return settings;
  }

  saveComposition(accountId: string, settings: CompositionSettings): Promise<void> {
    const values = normalizeComposition(settings);
    return this.enqueue(async () => {
      await this.database().executeSql("INSERT OR REPLACE INTO account_composition (account_id, sender_name, signature) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
        [accountId, values.senderName, values.signature, accountId]);
    });
  }

  async prepareNewOutgoing(accountId: string, draft: OutgoingDraft): Promise<void> {
    if (!draft.compositionApplied) { applyComposition(draft, await this.composition(accountId)); }
  }

  async mathSettings(accountId: string): Promise<MathSettings> {
    let settings = new MathSettings();
    await this.enqueue(async () => {
      const rows = await this.database().querySql("SELECT c.render_reading, c.send_format, c.renderer FROM account_math c JOIN accounts a ON a.id = c.account_id WHERE c.account_id = ? AND a.status = 'ready'", [accountId]);
      try {
        if (rows.goToFirstRow()) { settings = normalizeMathSettings({ renderWhileReading: rows.getLong(0) === 1, sendFormat: rows.getString(1), renderer: rows.getString(2) }); }
      } finally { rows.close(); }
    });
    return settings;
  }

  saveMathSettings(accountId: string, settings: MathSettings): Promise<void> {
    const value = normalizeMathSettings(settings);
    return this.enqueue(async () => {
      await this.database().executeSql("INSERT OR REPLACE INTO account_math (account_id, render_reading, send_format, renderer) SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
        [accountId, value.renderWhileReading ? 1 : 0, value.sendFormat, value.renderer!, accountId]);
    });
  }

  async rememberRecipients(accountId: string, fields: RecipientFields, when: number): Promise<void> {
    const history = this.recipientStore;
    if (!history) { return; }
    const messages: CachedEmail[] = await this.mail.cachedMessages(accountId, false).catch((): CachedEmail[] => []);
    await history.remember(accountId, sentRecipients(fields, knownRecipientNames(messages.map((record: CachedEmail): JmapEmail => record.mail)), when));
  }

  saveOutgoing(accountId: string, draft: OutgoingDraft): Promise<void> {
    if (draft.attachments !== undefined && (!Array.isArray(draft.attachments) ||
      (draft.attachments.length > 0 && !outgoingAttachmentsOwned(accountId, draft.id, draft.attachments)))) {
      return Promise.reject(new Error('Invalid draft attachments'));
    }
    const payload = JSON.stringify(draft);
    if (payload.length > 2 * 1024 * 1024) { return Promise.reject(new Error('Draft is too large')); }
    return this.enqueue(async () => {
      await this.database().executeSql("INSERT OR REPLACE INTO outgoing_drafts (account_id, payload) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [accountId, payload, accountId]);
    });
  }

  clearOutgoing(accountId: string, expectedDraftId?: string): Promise<void> {
    return this.enqueue(async () => {
      if (!outgoingAccountValid(accountId) || (expectedDraftId !== undefined && !outgoingUUIDValid(expectedDraftId))) {
        throw new Error('Invalid draft owner');
      }
      const rows = await this.database().querySql(`SELECT
        CASE WHEN json_valid(payload) THEN substr(json_extract(payload, '$.id'), 1, 37) ELSE '' END,
        CASE WHEN json_valid(payload) THEN substr(json_extract(payload, '$.state'), 1, 16) ELSE '' END
        FROM outgoing_drafts WHERE account_id = ?`, [accountId]);
      let id = '', state = '', found = false;
      try { if (rows.goToFirstRow()) { found = true; id = rows.getString(0); state = rows.getString(1); } }
      finally { rows.close(); }
      // A delayed discard cannot remove a newer draft or the files retained by
      // a confirmed send. Unpersisted selections are harmless startup orphans.
      if (!found) { return; }
      if (!outgoingUUIDValid(id)) { throw new Error('Invalid draft owner'); }
      if (expectedDraftId !== undefined && id !== expectedDraftId) { return; }
      if (state !== 'draft') { throw new Error('Draft cannot be discarded'); }
      await this.database().executeSql(`DELETE FROM outgoing_drafts WHERE account_id = ?
        AND json_valid(payload) AND json_extract(payload, '$.id') = ? AND json_extract(payload, '$.state') = 'draft'`, [accountId, id]);
      const current = await this.database().querySql(`SELECT 1 FROM outgoing_drafts WHERE account_id = ?
        AND json_valid(payload) AND json_extract(payload, '$.id') = ?`, [accountId, id]);
      try { if (current.goToFirstRow()) { throw new Error('Draft changed before discard'); } }
      finally { current.close(); }
      // Metadata is durably removed first. Cleanup failure leaves an orphan for
      // bounded startup cleanup, never a dangling saved-draft reference.
      await this.outgoingFiles?.forgetDraft(accountId, id).catch(() => {});
    });
  }

  private async pruneOutgoingFiles(): Promise<void> {
    const files = this.outgoingFiles;
    if (!files) { return; }
    await this.enqueue(async () => {
      const retained: Set<string> = new Set();
      // SQLite returns only the owner, never draft text or attachment bytes.
      // Keep every durable draft state, including uncertain and confirmed sends.
      const drafts = await this.database().querySql(`SELECT account_id,
        CASE WHEN json_valid(payload) THEN substr(json_extract(payload, '$.id'), 1, 37) ELSE '' END
        FROM outgoing_drafts`);
      try { while (drafts.goToNextRow()) {
        const account = drafts.getString(0), id = drafts.getString(1);
        if (!outgoingAccountValid(account) || !outgoingUUIDValid(id)) { return; }
        retained.add(`${account}/${id.toLowerCase()}`);
      } } finally { drafts.close(); }
      const messages = await this.database().querySql(`SELECT account_id,
        CASE WHEN json_valid(payload) THEN json_type(payload, '$.mail') = 'object'
          AND json_type(payload, '$.mail.id') = 'text'
          AND coalesce(json_type(payload, '$.mail.cachedSourceId'), 'null') IN ('text', 'null')
          AND json_type(payload, '$.bodySavedAt') IN ('integer', 'real', 'null') ELSE 0 END,
        CASE WHEN json_valid(payload) THEN coalesce(json_extract(payload, '$.bodySavedAt'), -1) ELSE -1 END,
        CASE WHEN json_valid(payload) THEN substr(json_extract(payload, '$.mail.id'), 1, 48) ELSE '' END,
        CASE WHEN json_valid(payload) THEN coalesce(substr(json_extract(payload, '$.mail.cachedSourceId'), 1, 48), '') ELSE '' END
        FROM mail_cache WHERE kind = 'email'`);
      try { while (messages.goToNextRow()) {
        const account = messages.getString(0), valid = messages.getLong(1), savedAt = messages.getDouble(2);
        if (!outgoingAccountValid(account) || valid !== 1 || !Number.isFinite(savedAt)) { return; }
        if (!cacheIsFresh(savedAt)) { continue; }
        for (const origin of [messages.getString(3), messages.getString(4)]) {
          if (!origin.startsWith('local_sent_')) { continue; }
          const id = origin.slice('local_sent_'.length);
          if (!outgoingUUIDValid(id)) { return; }
          retained.add(`${account}/${id.toLowerCase()}`);
        }
      } } finally { messages.close(); }
      // The database queue stays held until this one bounded pass ends, so a
      // queued metadata save cannot acquire a previously unretained old file.
      await files.prune(Array.from(retained));
    });
  }

  async outgoingAttachmentData(accountId: string, draft: OutgoingDraft): Promise<SmtpAttachmentData[]> {
    const files = this.outgoingFiles, attachments = draft.attachments ?? [];
    if (attachments.length === 0) { return []; }
    if (!files || !outgoingAttachmentsOwned(accountId, draft.id, attachments)) { throw new Error('Invalid draft attachments'); }
    const values = attachments.map((item: OutgoingAttachment): OutgoingAttachment => ({ id: item.id, name: item.name, contentType: item.contentType, size: item.size, file: item.file }));
    const requireAccount = async (): Promise<void> => {
      let ready = false;
      await this.enqueue(async () => {
        const rows = await this.database().querySql("SELECT 1 FROM accounts WHERE id = ? AND status = 'ready'", [accountId]);
        try { ready = rows.goToFirstRow(); } finally { rows.close(); }
      });
      if (!ready) { throw new Error('Attachment account is unavailable'); }
    };
    await requireAccount();
    const result: SmtpAttachmentData[] = [];
    for (const attachment of values) { result.push(await files.read(accountId, draft.id, attachment)); }
    await requireAccount();
    return result;
  }

  remove(id: string): Promise<void> {
    return this.enqueue(async () => {
      await this.database().executeSql("UPDATE accounts SET status = 'deleting' WHERE id = ?", [id]);
      await this.database().executeSql('DELETE FROM account_preferences WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_notifications WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_unread_badges WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM oauth_refresh_lease WHERE account_id = ?', [id]);
      await this.revokeBackgroundAccess(id);
      await OAuthSecretBox.remove(this.oauthAlias(id));
      await this.database().executeSql('DELETE FROM oauth_credentials WHERE account_id = ?', [id]);
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.alias(id)));
      try { await asset.remove(query); }
      catch (error) { if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw new Error('Credential removal failed'); } }
      const smtpQuery: asset.AssetMap = new Map();
      smtpQuery.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.smtpAlias(id)));
      try { await asset.remove(smtpQuery); }
      catch (error) { if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw new Error('Outgoing credentials could not be updated'); } }
      await this.database().executeSql('DELETE FROM outgoing_drafts WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM recipient_history WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM account_mail_actions WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM account_composition WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM account_math WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_cache WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM picture_cache WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM picture_snapshot WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM prepared_documents WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_sync_jobs WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_sync_cursors WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM picture_consent WHERE account_id = ?', [id]);
      if (this.cacheDir !== '') { AttachmentFiles.forgetAccount(this.cacheDir, id); }
      if (this.filesDir !== '') { AttachmentFiles.forgetAccount(this.filesDir, id); }
      await this.outgoingFiles?.forgetAccount(id);
      await this.contentFiles?.forgetAccount(id);
      await this.database().executeSql('DELETE FROM accounts WHERE id = ?', [id]);
    });
  }

  close(): Promise<void> {
    if (this.closing) { return this.closing; }
    const closing = this.finishClose();
    this.closing = closing;
    closing.then(() => { if (this.closing === closing) { this.closing = undefined; } },
      () => { if (this.closing === closing) { this.closing = undefined; } });
    return closing;
  }

  private async finishClose(): Promise<void> {
    try { await this.opening; } catch (_) {}
    await this.notificationChanges;
    await Promise.all(Array.from(this.refreshing.values()).map(task => task.catch(() => '')));
    while (this.mailSyncTasks.size > 0) { await Promise.all(Array.from(this.mailSyncTasks).map(task => task.catch(() => {}))); }
    await this.pictureCache?.whenIdle();
    if (!this.db) { return; }
    // Queue a final barrier: work submitted before it drains first, and work
    // carrying the old database after it is rejected by enqueue's identity.
    await this.enqueue(async () => {
      try { await this.db?.close(); } catch (_) {}
      ++this.databaseRevision;
      this.db = undefined;
      this.mailCache = undefined;
      this.pictureCache = undefined;
      this.preparedDocuments = undefined;
      this.mailSyncData = undefined;
      this.recipientStore = undefined;
      this.notificationData = undefined;
      this.unreadBadges = undefined;
    });
  }
}
