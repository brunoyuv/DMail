// Native UI observation of synthetic inbox events; no socket, pull gesture or mail access.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const component = await driver.waitForComponent(ON.id(id), 4000);
  expect(component !== null).assertTrue(); return component;
}

export default function tests(): void {
  describe('InboxAutomaticUI', () => {
    it('event_updates_cached_inbox_without_pull_and_preserves_open_reader', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      await delegator.print('INBOX_AUTOMATIC_UI_STAGE: bounded emulator unlock and warmup\n');
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
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'automatic-ui-synthetic-token', 'beta@example.test');
        const inbox = navigationMailbox(); inbox.totalEmails = 1;
        const original = navigationMail('Beta', 0, 0, true);
        await store.mail.saveBoxes(account.id, [inbox], false);
        await store.mail.saveView(account.id, 'inbox', [original]); await store.mail.saveEmail(account.id, original);
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        const bodySavedAt = (await store.mail.email(account.id, original.id, true))!.bodySavedAt;
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');
        await required(driver, 'remote-mail-mail-00'); await driver.delayMs(450);
        expect(ability.navigationCallCount()).assertEqual(0);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();

        await delegator.print('INBOX_AUTOMATIC_UI_STAGE: ignore foreign account and coalesce new-message events\n');
        // Only enable the UI bus; the production watcher/service lifecycle is
        // deliberately absent from PreviewTestAbility and remains stopped.
        ability.setNavigationInboxForeground(true);
        ability.setNavigationInboxSize(2);
        ability.requestNavigationInboxUpdate('synthetic-other-account'); await driver.delayMs(700);
        expect(ability.navigationCallCount()).assertEqual(0);
        expect(await driver.findComponent(ON.id('remote-mail-mail-01')) === null).assertTrue();
        for (let event = 0; event < 3; event++) { ability.requestNavigationInboxUpdate(account.id); }
        await required(driver, 'remote-mail-mail-01'); await driver.delayMs(450);
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage');
        expect((await store.mail.view(account.id, 'inbox', true))!.emails.length).assertEqual(2);

        await delegator.print('INBOX_AUTOMATIC_UI_STAGE: keep cached reader selected during another inbox arrival\n');
        await (await required(driver, 'remote-mail-mail-00')).click();
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual(original.subject);
        expect(await driver.waitForComponent(ON.text('Beta cached body'), 4000) !== null).assertTrue();
        ability.setNavigationInboxSize(3); ability.requestNavigationInboxUpdate(account.id);
        for (let attempt = 0; attempt < 50; attempt++) {
          if ((await store.mail.view(account.id, 'inbox', true))!.emails.some(mail => mail.id === 'mail-02')) { break; }
          await driver.delayMs(70);
        }
        expect((await store.mail.view(account.id, 'inbox', true))!.emails.length).assertEqual(3);
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual(original.subject);
        expect(await driver.findComponent(ON.text('Beta cached body')) !== null).assertTrue();
        const retained = (await store.mail.email(account.id, original.id, true))!;
        expect(retained.mail.textBody).assertEqual('Beta cached body'); expect(retained.bodySavedAt).assertEqual(bodySavedAt);
        await driver.pressBack(); await required(driver, 'remote-mail-mail-02');
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage,Beta:emailPage');
        expect(ability.navigationViolationCount()).assertEqual(0);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();
        await delegator.print('INBOX_AUTOMATIC_UI_RESULT: automatic rows, event coalescing, account guard and selected cached reader passed; two Inbox pages only, no bodies, mailboxes or Sent requests, alerts remain off\n');
      } finally {
        await delegator.print('INBOX_AUTOMATIC_UI_STAGE: clean isolated fixture\n');
        ability.setNavigationInboxForeground(false);
        try { await ability.hideNavigationFixture(); await driver.delayMs(150); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
