// MPL-2.0: https://mozilla.org/MPL/2.0/
// Isolated synthetic credentials only. No UI control or provider requests.
import { describe, it, expect } from '@ohos/hypium';
import { relationalStore } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { AccountStore, SavedAccount } from '../../../main/ets/data/AccountStore';
import { NativeBrowserOAuth, OAuthRegistration, OAuthTokens } from '../../../main/ets/mail/oauth/NativeBrowserOAuth';
import { RegisteredMailOAuth, SavedOAuthLogin } from '../../../main/ets/mail/oauth/RegisteredMailOAuth';

const coldDatabase = 'oauth_cold_stress.db';
const closingDatabase = 'oauth_closing_stress.db';

function login(expired: boolean): SavedOAuthLogin {
  return { registration: { provider: 'microsoft', clientID: RegisteredMailOAuth.clientID('microsoft'),
    redirectURI: 'http://127.0.0.1:49152/oauth2redirect', microsoftPersonalOnly: true },
    username: 'synthetic@example.test', tokens: { accessToken: 'synthetic-access',
      refreshToken: 'synthetic-refresh', expiresAt: Date.now() / 1000 + (expired ? -1 : 3600) } };
}

async function add(store: AccountStore, expired: boolean): Promise<SavedAccount> {
  return store.add(RegisteredMailOAuth.incoming('microsoft'),
    { id: 'default', name: 'Synthetic Outlook', isPersonal: true, isReadOnly: false },
    '', 'synthetic@example.test', undefined, login(expired));
}

class SyntheticRefresh extends NativeBrowserOAuth {
  calls: number = 0;
  async refresh(_registration: OAuthRegistration, token: string): Promise<OAuthTokens> {
    this.calls++;
    expect(token).assertEqual('synthetic-refresh');
    await new Promise<void>((resolve) => { setTimeout(resolve, 20); });
    return { accessToken: 'rotated-access', refreshToken: 'rotated-refresh', expiresAt: Date.now() / 1000 + 3600 };
  }
}

export function seedTests(): void {
  describe('OAuthColdSeed', () => {
    it('persist_for_a_separate_process', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const store = new AccountStore(coldDatabase);
      await store.open(delegator.getAppContext().createModuleContext('entry'));
      try {
        expect((await store.list()).length).assertEqual(0);
        await add(store, false);
      } finally { await store.close(); }
      await delegator.print('OAUTH_STRESS: seed-persisted\n');
    });
  });
}

export default function tests(): void {
  describe('OAuthReopenStress', () => {
    it('restore_after_process_restart_and_repeat_encrypted_reads', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext().createModuleContext('entry');
      for (let cycle = 0; cycle < 8; cycle++) {
        const store = new AccountStore(coldDatabase);
        const service = new SyntheticRefresh(); store.oauthService = service;
        await store.open(context);
        try {
          const accounts = await store.list(); expect(accounts.length).assertEqual(1);
          expect(accounts[0].username).assertEqual('synthetic@example.test');
          const calls: Promise<string>[] = [];
          for (let request = 0; request < 8; request++) { calls.push(store.oauthAccessToken(accounts[0])); }
          expect((await Promise.all(calls)).every(token => token === 'synthetic-access')).assertTrue();
          expect(service.calls).assertEqual(0);
          if (cycle === 7) { await store.remove(accounts[0].id); }
        } finally { await store.close(); }
      }
      await relationalStore.deleteRdbStore(context, coldDatabase);
      await delegator.print('OAUTH_STRESS: cold-reopen=8 credential-reads=64\n');
    });

    it('close_immediately_during_expired_credential_reads_and_reopen', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext().createModuleContext('entry');
      for (let cycle = 0; cycle < 12; cycle++) {
        const store = new AccountStore(closingDatabase);
        const service = new SyntheticRefresh(); store.oauthService = service;
        await store.open(context);
        try {
          const account = await add(store, true);
          const calls: Promise<string>[] = [];
          for (let request = 0; request < 8; request++) { calls.push(store.oauthAccessToken(account)); }
          const results = Promise.all(calls);
          const closed = store.close();
          expect((await results).every(token => token === 'rotated-access')).assertTrue();
          await closed;
          expect(service.calls).assertEqual(1);
          await store.open(context);
          const restored = (await store.list())[0];
          expect(await store.oauthAccessToken(restored)).assertEqual('rotated-access');
          expect(service.calls).assertEqual(1);
          await store.remove(restored.id);
        } finally { await store.close(); }
      }
      await relationalStore.deleteRdbStore(context, closingDatabase);
      await delegator.print('OAUTH_STRESS: close-refresh-reopen=12 concurrent-reads=96 persisted-reads=12\n');
    });
  });
}
