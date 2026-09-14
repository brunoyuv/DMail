// Socket-free reader retry and packaged Gmail app-password policy check.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { RegisteredMailOAuth, SavedOAuthLogin } from '../../../main/ets/mail/oauth/RegisteredMailOAuth';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const component = await driver.waitForComponent(ON.id(id), 3000);
  if (component === null) {
    await abilityDelegatorRegistry.getAbilityDelegator().print(`READER_RECOVERY_MISSING: ${id}\n`);
  }
  expect(component !== null).assertTrue(); return component;
}
async function absent(driver: Driver, id: string): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (await driver.findComponent(ON.id(id)) === null) { return; }
    await driver.delayMs(50);
  }
  await abilityDelegatorRegistry.getAbilityDelegator().print(`READER_RECOVERY_UNEXPECTED: ${id}\n`);
  expect(await driver.findComponent(ON.id(id)) === null).assertTrue();
}

export default function tests(): void {
  describe('ReaderRecovery', () => {
    it('old_header_retry_caches_body_and_packaged_gmail_policy_is_visible', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      await delegator.print('READER_RECOVERY_STAGE: bounded emulator unlock and warmup\n');
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(5000);
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      expect(await driver.waitForComponent(ON.text('Preparing mail preview'), 5000) !== null).assertTrue();
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      let passed = false;
      try {
        ability.resetNavigationFixtureState(); ability.enableNavigationReaderRecovery();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const login: SavedOAuthLogin = {
          registration: { provider: 'google', clientID: RegisteredMailOAuth.clientID('google'),
            redirectURI: 'http://127.0.0.1:45678/oauth2redirect' }, username: 'beta@example.test',
          tokens: { accessToken: 'synthetic-access-only', refreshToken: 'synthetic-refresh-only', expiresAt: Date.now() / 1000 + 3600 }
        };
        // The explicitly enabled NavigationClient factory ignores credentials
        // and intercepts this endpoint in memory. No Google service is called.
        const account = await store.add(RegisteredMailOAuth.incoming('google'), navigationAccount('Beta'), '',
          'beta@example.test', undefined, login);
        const inbox = navigationMailbox(); inbox.totalEmails = 2;
        const header = navigationMail('Beta', 0, 0, true);
        header.subject = 'Old synthetic message'; header.textBody = null; header.receivedAt = 1704067200000;
        const retained = navigationMail('Beta', 1, 0, true);
        await store.mail.saveBoxes(account.id, [inbox], false);
        await store.mail.saveView(account.id, 'inbox', [header, retained]);
        await store.mail.saveEmail(account.id, retained);
        const retainedSavedAt = (await store.mail.email(account.id, retained.id, true))!.bodySavedAt;
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');
        await required(driver, 'remote-mail-mail-00'); await driver.delayMs(450);
        expect(ability.navigationCallCount()).assertEqual(0);

        await delegator.print('READER_RECOVERY_STAGE: old header network failure offers explicit Retry\n');
        await (await required(driver, 'remote-mail-mail-00')).click();
        await driver.delayMs(450);
        await required(driver, 'connection-error'); await required(driver, 'body-not-saved');
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual(header.subject);
        await (await required(driver, 'refresh-message')).click();
        await required(driver, 'html-mail'); await absent(driver, 'body-not-saved');
        await absent(driver, 'connection-error'); await absent(driver, 'refresh-message');
        const recovered = (await store.mail.email(account.id, header.id, true))!;
        expect(recovered.mail.textBody).assertEqual('Recovered synthetic old message body');
        expect(recovered.mail.receivedAt).assertEqual(header.receivedAt);
        expect(ability.navigationCallSummary()).assertEqual('Beta:readEmail,Beta:readEmail');

        await delegator.print('READER_RECOVERY_STAGE: downloaded copy reopens offline without another request\n');
        ability.setNavigationReaderOffline();
        await driver.pressBack(); await driver.delayMs(450);
        await (await required(driver, 'remote-mail-mail-00')).click(); await driver.delayMs(450);
        await required(driver, 'html-mail'); await absent(driver, 'refresh-message');
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual(header.subject);
        const reopened = (await store.mail.email(account.id, header.id, true))!;
        expect(reopened.mail.textBody).assertEqual(recovered.mail.textBody);
        expect(reopened.bodySavedAt).assertEqual(recovered.bodySavedAt);
        const preserved = (await store.mail.email(account.id, retained.id, true))!;
        expect(preserved.mail.textBody).assertEqual(retained.textBody);
        expect(preserved.bodySavedAt).assertEqual(retainedSavedAt);

        await delegator.print('READER_RECOVERY_STAGE: default Gmail app-password guidance without opening browser\n');
        await driver.pressBack(); await driver.delayMs(450);
        await (await required(driver, 'open-mailboxes')).click(); await driver.delayMs(450);
        await (await required(driver, 'open-accounts')).click(); await driver.delayMs(450);
        if (RegisteredMailOAuth.googleBrowserSignInEnabled) {
          expect(await (await required(driver, `reconnect-${account.id}`)).isEnabled()).assertTrue();
          await required(driver, 'oauth-google');
        } else {
          await absent(driver, `reconnect-${account.id}`);
          await absent(driver, 'oauth-google');
          const guidance = await required(driver, 'gmail-app-password-help');
          expect((await guidance.getText()).includes('use a Google app password')).assertTrue();
        }
        await required(driver, 'oauth-microsoft');
        await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/d-mail-account-setup.png');
        await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
          Math.round(screen.width / 2), Math.round(screen.height * 0.35), 600);
        await driver.delayMs(250);
        await required(driver, 'account-token');
        expect((await store.list())[0].id).assertEqual(account.id);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();
        expect(ability.navigationCallSummary()).assertEqual('Beta:readEmail,Beta:readEmail');
        expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('READER_RECOVERY_RESULT: explicit Retry recovered old body, offline cache and other downloaded body preserved, packaged Gmail policy verified; exactly two synthetic body requests, no other mail calls or browser\n');
        passed = true;
      } finally {
        if (!passed) {
          try {
            const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/reader-recovery-failure.png');
            await delegator.print(`READER_RECOVERY_FAILURE_SCREEN: exit ${capture.exitCode}\n`);
          } catch (_) {}
        }
        await delegator.print('READER_RECOVERY_STAGE: clean isolated fixture\n');
        try { await ability.hideNavigationFixture(); await driver.delayMs(150); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
