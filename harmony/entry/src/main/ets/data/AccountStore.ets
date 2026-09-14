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
import { MailCache } from './MailCache';
import { CachedEmail } from './MailCacheModel';
import { PictureCache } from './PictureCache';
import { RecipientStore } from './RecipientStore';
import { RecipientRecord, RecipientFields, sentRecipients, cachedSentRecipients, knownRecipientNames } from './RecipientHistory';
import { CompositionSettings, normalizeComposition, applyComposition } from './CompositionSettings';
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
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      const secret = results[0]?.get(asset.Tag.SECRET) as Uint8Array;
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
  private name: string;
  private mailCache?: MailCache;
  private pictureCache?: PictureCache;
  private recipientStore?: RecipientStore;
  private notificationData?: NotificationStore;
  private unreadBadges?: UnreadBadgeStore;
  private notificationChanges: Promise<void> = Promise.resolve();
  private cacheDir: string = '';
  private refreshing: Map<string, Promise<string>> = new Map();
  oauthService: NativeBrowserOAuth = new NativeBrowserOAuth();
  constructor(name: string = 'thunderbird_accounts.db') { this.name = name; }

  async open(context: common.Context): Promise<void> {
    if (this.db && !this.opening) { return; }
    if (!this.opening) { this.opening = this.initialize(context); }
    try { await this.opening; }
    finally { this.opening = undefined; }
  }

  async openForMailChecks(context: common.Context): Promise<void> {
    if (this.db && !this.opening) { return; }
    if (!this.opening) { this.opening = this.initializeForMailChecks(context); }
    try { await this.opening; }
    finally { this.opening = undefined; }
  }

  private async initializeForMailChecks(context: common.Context): Promise<void> {
    try {
      this.db = await relationalStore.getRdbStore(context, { name: this.name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
      if (this.db.version !== 5) { throw new Error('Account storage is not initialized'); }
      // Background work may share the DB with account setup. Never migrate,
      // prune message/picture caches or remove a pending foreground account.
      const rows = await this.db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('accounts', 'oauth_credentials', 'mail_notifications', 'mail_check_lease', 'oauth_refresh_lease')");
      let tables = 0;
      try { while (rows.goToNextRow()) { tables++; } } finally { rows.close(); }
      if (tables !== 5) { throw new Error('Mail checking is not initialized'); }
      this.notificationData = new NotificationStore(this.db, operation => this.enqueue(operation));
      const badgeTable = await this.db.querySql("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'mail_unread_badges'");
      let badgesAvailable = false;
      try { badgesAvailable = badgeTable.goToFirstRow(); } finally { badgeTable.close(); }
      this.unreadBadges = new UnreadBadgeStore(this.db, operation => this.enqueue(operation), badgesAvailable);
    } catch (_) {
      try { this.db?.close(); } catch (_) {}
      this.db = undefined; throw new Error('Mail checking storage is unavailable');
    }
  }

  private async initialize(context: common.Context): Promise<void> {
    this.cacheDir = context.cacheDir;
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
      await MailCache.initialize(this.db);
      await PictureCache.initialize(this.db);
      await RecipientStore.initialize(this.db);
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS account_composition (account_id TEXT PRIMARY KEY, sender_name TEXT NOT NULL, signature TEXT NOT NULL)');
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS outgoing_drafts (account_id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
      // Additive UI metadata remains compatible with the version-five account
      // schema. Keep the selection inside this encrypted, per-store database.
      await this.db.executeSql('CREATE TABLE IF NOT EXISTS account_preferences (name TEXT PRIMARY KEY, account_id TEXT NOT NULL)');
      this.db.version = 5;
      this.unreadBadges = new UnreadBadgeStore(this.db, operation => this.enqueue(operation));
      this.mailCache = new MailCache(this.db, (operation) => this.enqueue(operation), this.unreadBadges);
      this.pictureCache = new PictureCache(this.db, (operation) => this.enqueue(operation));
      this.recipientStore = new RecipientStore(this.db, (operation) => this.enqueue(operation));
      this.notificationData = new NotificationStore(this.db, (operation) => this.enqueue(operation));
      const interrupted = await this.rows("SELECT * FROM accounts WHERE status != 'ready'");
      for (const account of interrupted) { await this.remove(account.id); }
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
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias)); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const results = await asset.query(query), bytes = results[0]?.get(asset.Tag.SECRET) as Uint8Array;
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
    await this.pending;
    return this.rows("SELECT * FROM accounts WHERE status = 'ready' ORDER BY name, id");
  }

  async lastVisitedAccount(): Promise<SavedAccount | null> {
    await this.pending;
    const accounts = await this.rows("SELECT a.* FROM accounts a JOIN account_preferences p ON p.account_id = a.id WHERE p.name = 'last_visited' AND a.status = 'ready'");
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

  private enqueue(operation: () => Promise<void>): Promise<void> {
    const task = this.pending.catch(() => {}).then(operation);
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
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(this.smtpAlias(account.id)));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      const secret = results[0]?.get(asset.Tag.SECRET) as Uint8Array;
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
    await this.pending;
    const result = await this.database().querySql('SELECT payload FROM outgoing_drafts WHERE account_id = ?', [accountId]);
    try {
      if (!result.goToFirstRow()) { return null; }
      const draft = JSON.parse(result.getString(0)) as OutgoingDraft;
      // A process may have stopped after DATA was accepted but before storage.
      if (draft.state === 'sending' && !sendingActive) { draft.state = 'unconfirmed'; }
      return draft;
    } finally { result.close(); }
  }

  async recipients(accountId: string): Promise<RecipientRecord[]> {
    const history = this.recipientStore;
    if (!history) { return []; }
    // Upgrade from downloaded, explicitly identified Sent mail only. Drafts,
    // the incoming address book, and failed submissions cannot seed history.
    const messages: CachedEmail[] = await this.mail.cachedMessages(accountId).catch((): CachedEmail[] => []);
    const boxes = await this.mail.boxes(accountId).catch(() => null);
    await history.remember(accountId, cachedSentRecipients(messages.map((record: CachedEmail): JmapEmail => record.mail), boxes?.boxes || []));
    return history.list(accountId);
  }

  async composition(accountId: string): Promise<CompositionSettings> {
    await this.pending;
    const rows = await this.database().querySql("SELECT c.sender_name, c.signature FROM account_composition c JOIN accounts a ON a.id = c.account_id WHERE c.account_id = ? AND a.status = 'ready'", [accountId]);
    try {
      if (!rows.goToFirstRow()) { return new CompositionSettings(); }
      return normalizeComposition({ senderName: rows.getString(0), signature: rows.getString(1) });
    } finally { rows.close(); }
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

  async rememberRecipients(accountId: string, fields: RecipientFields, when: number): Promise<void> {
    const history = this.recipientStore;
    if (!history) { return; }
    const messages: CachedEmail[] = await this.mail.cachedMessages(accountId).catch((): CachedEmail[] => []);
    await history.remember(accountId, sentRecipients(fields, knownRecipientNames(messages.map((record: CachedEmail): JmapEmail => record.mail)), when));
  }

  saveOutgoing(accountId: string, draft: OutgoingDraft): Promise<void> {
    const payload = JSON.stringify(draft);
    if (payload.length > 2 * 1024 * 1024) { return Promise.reject(new Error('Draft is too large')); }
    return this.enqueue(async () => {
      await this.database().executeSql("INSERT OR REPLACE INTO outgoing_drafts (account_id, payload) SELECT ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')", [accountId, payload, accountId]);
    });
  }

  clearOutgoing(accountId: string): Promise<void> {
    return this.enqueue(async () => { await this.database().executeSql('DELETE FROM outgoing_drafts WHERE account_id = ?', [accountId]); });
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
      await this.database().executeSql('DELETE FROM account_composition WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM mail_cache WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM picture_cache WHERE account_id = ?', [id]);
      await this.database().executeSql('DELETE FROM picture_consent WHERE account_id = ?', [id]);
      if (this.cacheDir !== '') { AttachmentFiles.forgetAccount(this.cacheDir, id); }
      await this.database().executeSql('DELETE FROM accounts WHERE id = ?', [id]);
    });
  }

  async close(): Promise<void> {
    try { await this.opening; } catch (_) {}
    await this.notificationChanges;
    await Promise.all(Array.from(this.refreshing.values()).map(task => task.catch(() => '')));
    await this.pictureCache?.whenIdle();
    await this.pending;
    try { this.db?.close(); } catch (_) {}
    this.db = undefined;
    this.mailCache = undefined;
    this.pictureCache = undefined;
    this.recipientStore = undefined;
    this.notificationData = undefined;
    this.unreadBadges = undefined;
  }
}
