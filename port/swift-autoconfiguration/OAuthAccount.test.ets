import { describe, it, expect, beforeAll } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { Driver } from '@ohos.UiTest';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
import { AccountStore, SavedAccount } from '../../../main/ets/data/AccountStore';
import { NativeBrowserOAuth, OAuthRegistration, OAuthTokens } from '../../../main/ets/mail/oauth/NativeBrowserOAuth';
import { RegisteredMailOAuth, SavedOAuthLogin } from '../../../main/ets/mail/oauth/RegisteredMailOAuth';
import { SmtpSettings } from '../../../main/ets/mail/smtp/NativeSmtpClient';

let fixtureContext: common.UIAbilityContext;

function login(expired: boolean = false): SavedOAuthLogin {
  return { registration: { provider: 'google', clientID: RegisteredMailOAuth.clientID('google'),
    redirectURI: 'http://127.0.0.1:45678/oauth2redirect' }, username: 'separate-login',
    tokens: { accessToken: 'synthetic-access', refreshToken: 'synthetic-refresh',
      expiresAt: Date.now() / 1000 + (expired ? -1 : 3600) } };
}
async function add(store: AccountStore, expired: boolean = false): Promise<SavedAccount> {
  return store.add(RegisteredMailOAuth.incoming('google'), { id: 'default', name: 'Synthetic OAuth', isPersonal: true, isReadOnly: false },
    '', 'identity@example.test', undefined, login(expired));
}
async function rejects(operation: () => Promise<string>): Promise<void> {
  let failed = false;
  try { await operation(); } catch (_) { failed = true; }
  expect(failed).assertTrue();
}
async function withStore(operation: (store: AccountStore, name: string) => Promise<void>): Promise<void> {
  const name = `oauth_${util.generateRandomUUID()}.db`;
  const context = fixtureContext;
  const store = new AccountStore(name);
  await store.open(context);
  try { await operation(store, name); }
  finally {
    for (const account of await store.list()) { await store.remove(account.id); }
    await store.close();
    await relationalStore.deleteRdbStore(context, name);
  }
}
class RefreshFixture extends NativeBrowserOAuth {
  calls: number = 0;
  release: () => void = () => {};
  entered: Promise<void>;
  private start: () => void = () => {};
  constructor() { super(); this.entered = new Promise<void>((resolve) => { this.start = resolve; }); }
  async refresh(_registration: OAuthRegistration, token: string): Promise<OAuthTokens> {
    this.calls++;
    expect(token).assertEqual('synthetic-refresh');
    const gate = new Promise<void>((resolve) => { this.release = resolve; });
    this.start(); await gate;
    return { accessToken: 'rotated-access', refreshToken: 'rotated-refresh', expiresAt: Date.now() / 1000 + 3600 };
  }
}
export default function tests(): void {
  describe('SavedOAuthAccounts', () => {
    beforeAll(async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(3000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      try {
        await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
        fixtureContext = (await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility).context;
      } finally { await delegator.removeAbilityMonitor(monitor); }
    });
    it('version_four_password_accounts_migrate_without_changing_credentials', 0, async () => {
      const name = `oauth_migration_${util.generateRandomUUID()}.db`;
      const context = fixtureContext;
      const db = await relationalStore.getRdbStore(context, { name: name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
      const id = util.generateRandomUUID();
      await db.executeSql('CREATE TABLE accounts (id TEXT PRIMARY KEY, server_id TEXT NOT NULL, name TEXT NOT NULL, session_url TEXT NOT NULL, status TEXT NOT NULL, email_address TEXT NOT NULL)');
      await db.executeSql('INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?)', [id, 'default', 'Existing', 'imaps://mail.example.test:993', 'ready', 'old@example.test']);
      db.version = 4; db.close();
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(`tb.jmap.${name}.${id}`));
      attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto('b2xkOnBhc3N3b3Jk'));
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      await asset.add(attributes);
      const store = new AccountStore(name);
      try {
        await store.open(context);
        const account = (await store.list())[0];
        expect(account.id).assertEqual(id); expect(account.authentication).assertEqual('');
        expect(account.emailAddress).assertEqual('old@example.test');
        expect(await store.credentials(account).authorization()).assertEqual('Basic b2xkOnBhc3N3b3Jk');
      } finally { await store.remove(id); await store.close(); await relationalStore.deleteRdbStore(context, name); }
    });
    it('account_reopens_with_separate_login_and_encrypted_token_record', 0, async () => {
      await withStore(async (store, name) => {
        const account = await add(store);
        const context = fixtureContext;
        await store.close(); await store.open(context);
        const saved = (await store.list())[0];
        expect(saved.id).assertEqual(account.id);
        expect(saved.emailAddress).assertEqual('identity@example.test');
        expect(store.credentials(saved).username).assertEqual('separate-login');
        expect(await store.credentials(saved).authorization()).assertEqual('Bearer synthetic-access');
        const db = await relationalStore.getRdbStore(context, { name: name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
        const result = await db.querySql('SELECT envelope FROM oauth_credentials WHERE account_id = ?', [account.id]);
        try {
          expect(result.goToFirstRow()).assertTrue();
          expect(result.getString(0).includes('synthetic-access')).assertFalse();
          expect(result.getString(0).includes('synthetic-refresh')).assertFalse();
        } finally { result.close(); }
      });
    });
    it('concurrent_expired_token_requests_share_one_refresh_and_persist_rotation', 0, async () => {
      await withStore(async (store, _name) => {
        const account = await add(store, true);
        const service = new RefreshFixture(); store.oauthService = service;
        const calls: Promise<string>[] = [];
        for (let index = 0; index < 8; index++) { calls.push(store.oauthAccessToken(account)); }
        const result = Promise.all(calls);
        await service.entered; service.release();
        expect((await result).every(token => token === 'rotated-access')).assertTrue();
        expect(service.calls).assertEqual(1);
        await store.close(); await store.open(fixtureContext);
        expect(await store.oauthAccessToken((await store.list())[0])).assertEqual('rotated-access');
        expect(service.calls).assertEqual(1);
      });
    });
    it('removal_during_refresh_cannot_recreate_credentials', 0, async () => {
      await withStore(async (store, _name) => {
        const account = await add(store, true);
        const service = new RefreshFixture(); store.oauthService = service;
        const request = store.oauthAccessToken(account); request.catch(() => {});
        await service.entered;
        await store.remove(account.id); service.release();
        await rejects(() => request);
        expect((await store.list()).length).assertEqual(0);
        await rejects(() => store.oauthAccessToken(account));
      });
    });
    it('oauth_token_cannot_be_requested_for_an_edited_smtp_host_or_login', 0, async () => {
      await withStore(async (store, _name) => {
        const account = await add(store);
        const settings = new SmtpSettings(); settings.username = 'separate-login';
        settings.endpoint = 'smtp://other.example.test:587';
        await rejects(() => store.oauthAccessToken(account, settings));
        settings.endpoint = RegisteredMailOAuth.outgoing('google'); settings.username = 'another-login';
        await rejects(() => store.oauthAccessToken(account, settings));
        settings.username = 'separate-login';
        expect(await store.oauthAccessToken(account, settings)).assertEqual('synthetic-access');
      });
    });
  });
}
