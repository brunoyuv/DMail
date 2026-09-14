// One bounded main-HAP UI smoke test with cached synthetic mail only. No SMTP.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 3000);
  expect(value !== null).assertTrue(); return value;
}
async function backTo(driver: Driver, id: string): Promise<void> {
  for (let attempt = 0; attempt < 4; attempt++) {
    if (await driver.findComponent(ON.id(id)) !== null) { return; }
    await driver.pressBack(); await driver.delayMs(150);
  }
  await required(driver, id);
}
async function editable(driver: Driver, id: string): Promise<Component> {
  const input = await required(driver, id);
  for (let attempt = 0; attempt < 20 && !await input.isEnabled(); attempt++) { await driver.delayMs(50); }
  expect(await input.isEnabled()).assertTrue(); return input;
}

export default function tests(): void {
  describe('ComposeSettings', () => {
    it('sent_title_recipient_selection_and_persisted_sender_signature', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      await delegator.print('COMPOSE_SETTINGS_STAGE: bounded emulator unlock and warmup\n');
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(5000);
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(await driver.waitForComponent(ON.text('Preparing mail preview'), 5000) !== null).assertTrue();
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      try {
        await delegator.print('COMPOSE_SETTINGS_STAGE: seed cached Inbox, Sent and local recipient\n');
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'compose-synthetic-token', 'beta@example.test');
        const inbox = navigationMailbox(); inbox.totalEmails = 1;
        const sent = navigationMailbox(); sent.id = 'sent'; sent.name = 'Synthetic server Sent'; sent.role = 'sent'; sent.totalEmails = 1;
        const received = navigationMail('Beta', 0, 0, true);
        received.from = [{ name: 'Alice Synthetic', email: 'alice@example.test' }];
        received.subject = 'Synthetic contact history';
        const outgoing = navigationMail('Beta', 1, 0, true); outgoing.mailboxIds = ['sent'];
        outgoing.subject = 'Synthetic Sent folder'; outgoing.to = [{ name: 'Alice Synthetic', email: 'alice@example.test' }];
        await store.mail.saveBoxes(account.id, [inbox, sent], false);
        await store.mail.saveView(account.id, 'inbox', [received]); await store.mail.saveEmail(account.id, received);
        await store.mail.saveView(account.id, 'sent', [outgoing]); await store.mail.saveEmail(account.id, outgoing);
        await store.rememberRecipients(account.id, { to: 'alice@example.test', cc: '', bcc: '' }, Date.now());
        await store.rememberVisitedAccount(account.id);
        await AppLanguage.set(ability.context, 'en'); application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');
        expect(await (await required(driver, 'inbox-title')).getText()).assertEqual('Inbox');
        await (await required(driver, 'open-mailboxes')).click();
        await (await required(driver, 'remote-box-sent')).click();
        await required(driver, 'remote-mail-mail-01');
        expect(await (await required(driver, 'inbox-title')).getText()).assertEqual('Sent');
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/compose-settings-sent.png')).exitCode).assertEqual(0);

        await delegator.print('COMPOSE_SETTINGS_STAGE: edit account sender and signature through Settings\n');
        await (await required(driver, 'open-mailboxes')).click(); await (await required(driver, 'open-settings')).click();
        await (await editable(driver, 'sender-display-name')).inputText('Synthetic Bruno');
        await (await editable(driver, 'account-signature')).inputText('Kind regards,\nSynthetic Bruno');
        for (let attempt = 0; attempt < 20; attempt++) {
          const value = await store.composition(account.id);
          if (value.senderName === 'Synthetic Bruno' && value.signature === 'Kind regards,\nSynthetic Bruno') { break; }
          await driver.delayMs(50);
        }
        const saved = await store.composition(account.id);
        expect(saved.senderName).assertEqual('Synthetic Bruno'); expect(saved.signature).assertEqual('Kind regards,\nSynthetic Bruno');
        await backTo(driver, 'remote-box-sent'); await (await required(driver, 'remote-box-sent')).click();
        expect(await (await required(driver, 'inbox-title')).getText()).assertEqual('Sent');

        await delegator.print('COMPOSE_SETTINGS_STAGE: select local recipient and preserve one signature on draft reopen\n');
        await (await required(driver, 'compose-mail')).click();
        const to = await editable(driver, 'compose-to');
        const signature = '\n\nKind regards,\nSynthetic Bruno';
        expect(await (await required(driver, 'compose-body')).getOriginalText()).assertEqual(signature);
        expect((await (await required(driver, 'compose-from-summary')).getText()).includes('Synthetic Bruno <beta@example.test>')).assertTrue();
        await to.inputText('ali');
        await (await required(driver, 'recipient-to-alice@example.test')).click();
        expect(await (await required(driver, 'compose-to')).getOriginalText()).assertEqual('alice@example.test');
        await driver.pressBack(); await required(driver, 'compose-panel');
        await (await required(driver, 'cancel-compose')).click();
        const saveDraft = await driver.waitForComponent(ON.text('Save draft'), 3000);
        expect(saveDraft !== null).assertTrue(); await saveDraft.click();
        await required(driver, 'inbox-title');
        const draft = await store.outgoing(account.id);
        expect(draft !== null).assertTrue(); expect(draft!.senderName).assertEqual('Synthetic Bruno');
        expect(draft!.text).assertEqual(signature); expect(draft!.to).assertEqual('alice@example.test');
        expect(draft!.compositionApplied).assertTrue();
        await (await required(driver, 'compose-mail')).click(); await editable(driver, 'compose-to');
        expect(await (await required(driver, 'compose-body')).getOriginalText()).assertEqual(signature);
        expect(await (await required(driver, 'compose-to')).getOriginalText()).assertEqual('alice@example.test');
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/compose-settings-composer.png')).exitCode).assertEqual(0);
        expect(ability.navigationCallCount()).assertEqual(0); expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('COMPOSE_SETTINGS_RESULT: Sent title, Settings autosave, local recipient choice, sender identity and signature-once draft reopen passed; zero mail service calls and no send\n');
      } finally {
        await delegator.print('COMPOSE_SETTINGS_STAGE: cleanup isolated test account\n');
        try { await ability.hideNavigationFixture(); await driver.delayMs(150); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); application.setColorMode(previousMode);
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
