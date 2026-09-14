import { describe, it, expect } from '@ohos/hypium';
import { discoveryRequest } from 'libthunderbird.so';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { display } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { FixtureDiscovery, configurationXml } from '../pages/DiscoveryFixture';
import { NativeMailDiscovery, MailConfiguration } from '../../../main/ets/mail/discovery/NativeMailDiscovery';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { SmtpSettings } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { JmapAccount } from '../../../main/ets/mail/jmap/JmapClient';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
interface Input { operation: string; email: string; document: string; }
interface Reply { configuration?: MailConfiguration; error?: string; }

async function reveal(driver: Driver, id: string): Promise<void> {
  const screen = display.getDefaultDisplaySync();
  for (let i = 0; i < 12; i++) {
    let scrollBack = false;
    const component = await driver.findComponent(ON.id(id));
    if (component !== null) {
      const box = await component.getBounds();
      if (box.top > screen.height * 0.26 && box.bottom < screen.height * 0.88) { return; }
      scrollBack = box.top < screen.height * 0.26;
    }
    await driver.swipe(Math.round(screen.width * 0.8), Math.round(screen.height * (scrollBack ? 0.4 : 0.75)),
      Math.round(screen.width * 0.8), Math.round(screen.height * (scrollBack ? 0.75 : 0.4)), 600);
    await driver.delayMs(250);
  }
  throw new Error(`Could not reveal ${id}`);
}

export default function tests(): void {
  let fixtureAbility: IMAPTestAbility | null = null;
  describe('NativeServerDiscovery', () => {
    it('original_parser_preserves_login_and_transport', 0, async () => {
      const config = await new FixtureDiscovery().discover('account@example.test');
      expect(config.incoming[0].username).assertEqual('account');
      expect(config.outgoing[0].username).assertEqual('smtp-account');
      expect(config.incoming[0].supported).assertTrue();
      expect(config.outgoing[0].security).assertEqual('STARTTLS');
    });
    it('unsupported_auth_is_not_changed_to_password', 0, async () => {
      const input: Input = { operation: 'parse', email: 'account@example.test',
        document: configurationXml.replace(/password-cleartext/g, 'OAuth2') };
      const reply = JSON.parse(await discoveryRequest(JSON.stringify(input))) as Reply;
      expect(reply.configuration?.incoming[0].supported).assertFalse();
      expect(reply.configuration?.incoming[0].reason).assertEqual('unsupportedAuthentication');
      expect(reply.configuration?.outgoing[0].supported).assertFalse();
      input.document = '<clientConfig';
      expect((JSON.parse(await discoveryRequest(JSON.stringify(input))) as Reply).error).assertEqual('invalidConfiguration');
    });
    it('public_https_discovery_uses_native_transport', 0, async () => {
      const config = await new NativeMailDiscovery().discover('harmony-port-fixture@gmail.com');
      expect(config.incoming.some(server => server.protocolName === 'imap')).assertTrue();
      expect(config.outgoing.some(server => server.protocolName === 'smtp')).assertTrue();
      console.info(`DISCOVERY_HTTPS: ${config.source}, ${config.incoming.length} incoming, ${config.outgoing.length} outgoing`);
    });
    it('account_and_separate_outgoing_login_survive_reopen', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(5000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      fixtureAbility = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      await delegator.removeAbilityMonitor(monitor);
      const context = fixtureAbility.context;
      const store = new AccountStore('discovery_storage_test.db'); await store.open(context);
      try {
        const server: JmapAccount = { id: 'default', name: 'account', isPersonal: true, isReadOnly: false };
        const smtp = new SmtpSettings(); smtp.endpoint = 'smtp://localhost:9772';
        smtp.username = 'smtp-account'; smtp.password = 'outgoing-password';
        const token = new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('account:incoming-password'));
        const account = await store.add('imaps://localhost:9761', server, token, 'account@example.test', smtp);
        await store.close(); await store.open(context);
        expect((await store.list()).find(value => value.id === account.id)?.emailAddress).assertEqual('account@example.test');
        expect((await store.credentials(account).authorization()).slice(6)).assertEqual(token);
        const outgoing = await store.smtp(account);
        expect(outgoing.username).assertEqual('smtp-account'); expect(outgoing.password).assertEqual('outgoing-password');
        await store.remove(account.id);
        expect((await store.smtp(account)).endpoint).assertEqual('');
        smtp.password = 'x'.repeat(4097);
        let rejected = false;
        try { await store.add('imaps://localhost:9761', server, token, 'account@example.test', smtp); }
        catch (_) { rejected = true; }
        expect(rejected).assertTrue(); expect((await store.list()).length).assertEqual(0);
      } finally { for (const account of await store.list()) { await store.remove(account.id); } await store.close(); }
    });
    it('discovered_settings_fill_native_account_form', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create();
      expect(fixtureAbility !== null).assertTrue();
      const ability = fixtureAbility!;
      await AppLanguage.set(ability.context, 'en');
      await ability.showDiscoveryFixture();
      await driver.waitForComponent(ON.id('oauth-microsoft').enabled(true), 10000);
      await reveal(driver, 'oauth-microsoft');
      expect(await (await driver.findComponent(ON.id('oauth-microsoft'))).getText()).assertEqual('Sign in with Outlook.com');
      expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/oauth-accounts.png')).exitCode).assertEqual(0);
      await driver.waitForComponent(ON.id('find-server-settings').enabled(true), 10000);
      await reveal(driver, 'find-server-settings');
      await (await driver.findComponent(ON.id('find-server-settings'))).click();
      await driver.delayMs(700);
      await reveal(driver, 'discovery-incoming-login');
      expect(await (await driver.findComponent(ON.id('discovery-incoming-login'))).getText()).assertEqual('account');
      await reveal(driver, 'discovery-apply');
      await driver.delayMs(700);
      expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/discovery-options.png')).exitCode).assertEqual(0);
      await (await driver.findComponent(ON.id('discovery-apply').enabled(true))).click();
      await reveal(driver, 'account-smtp-username');
      expect(await (await driver.findComponent(ON.id('account-smtp-username'))).getText()).assertEqual('smtp-account');
      await driver.delayMs(700);
      expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/discovery-applied.png')).exitCode).assertEqual(0);
      // No connection or message submission is triggered by applying a proposal.
    });
  });
}
