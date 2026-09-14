// Repeated native filtering over encrypted cached fixtures, with no sockets.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component, Rect } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 4000);
  expect(value !== null).assertTrue(); return value;
}
async function visibleRow(driver: Driver, id: string): Promise<Rect> {
  const row = await (await required(driver, `remote-mail-${id}`)).getBounds();
  const list = await (await required(driver, 'mail-list')).getBounds();
  expect(row.bottom > list.top + 2 && row.top < list.bottom - 2).assertTrue();
  return row;
}
async function filtered(driver: Driver): Promise<void> {
  await driver.delayMs(250);
  expect(await driver.waitForComponent(ON.text('Show all'), 4000) !== null).assertTrue();
  await visibleRow(driver, 'mail-00'); await visibleRow(driver, 'mail-04'); await visibleRow(driver, 'mail-38');
  // The thread qualifies because of the older unread member. Its newer read
  // representative must not be the displayed/opened item in the unread view.
  expect(await driver.findComponent(ON.id('remote-mail-mail-01')) === null).assertTrue();
  expect(await driver.findComponent(ON.id('remote-mail-mail-02')) === null).assertTrue();
}
async function allMail(driver: Driver): Promise<void> {
  await driver.delayMs(250);
  expect(await driver.waitForComponent(ON.text('Unread'), 4000) !== null).assertTrue();
  await visibleRow(driver, 'mail-01'); await visibleRow(driver, 'mail-02');
}
export default function tests(): void {
  describe('UnreadFilter', () => {
    it('repeated_filter_cycles_reset_scrolled_list_and_open_unread_thread_member', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.print('UNREAD_FILTER_STAGE: start synthetic ability\n');
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      await delegator.print('UNREAD_FILTER_STAGE: wait for rendered synthetic startup page\n');
      // The monitor reports ability creation before its window necessarily
      // finishes rendering. Do not immediately reload that startup window.
      expect(await driver.waitForComponent(ON.text('Preparing mail preview'), 5000) !== null).assertTrue();
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      await delegator.print('UNREAD_FILTER_STAGE: open synthetic cache\n');
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        expect(await driver.findComponent(ON.id('navigation-fixture-marker')) !== null).assertTrue();
        const list = await (await required(driver, 'mail-list')).getBounds();
        const filter = await (await required(driver, 'filter-unread')).getBounds();
        await delegator.print(`UNREAD_FILTER_BOUNDS: ${JSON.stringify({ name: name, list: list, filter: filter, calls: ability.navigationCallSummary() })}\n`);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/unread-filter-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        await delegator.print('UNREAD_FILTER_STAGE: seed synthetic messages\n');
        ability.resetNavigationFixtureState();
        for (const account of await store.list()) { await store.remove(account.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'unread-synthetic-token', 'beta@example.test');
        const mails: JmapEmail[] = [];
        for (let index = 0; index < 40; index++) {
          const mail = navigationMail('Beta', index, 0, true);
          mail.subject = `Synthetic message ${index.toString().padStart(2, '0')}`;
          mail.keywords = [0, 4, 38].includes(index) ? [] : ['$seen'];
          mails.push(mail);
        }
        const older = mails[0], newer = mails[1];
        older.subject = 'Older unread question'; older.textBody = 'Unread conversation body.';
        newer.subject = 'Latest already read reply'; newer.textBody = 'Already read reply body.';
        newer.receivedAt = older.receivedAt + 60000;
        newer.inReplyTo = older.messageIds; newer.references = older.messageIds;
        const ordered = [newer, older].concat(mails.slice(2));
        const box = navigationMailbox(); box.totalEmails = 40; box.unreadEmails = 3;
        await store.mail.saveBoxes(account.id, [box], false);
        await store.mail.saveView(account.id, 'inbox', ordered);
        await store.mail.saveEmail(account.id, older); await store.mail.saveEmail(account.id, newer);
        await store.rememberVisitedAccount(account.id);
        await delegator.print('UNREAD_FILTER_STAGE: configure synthetic app appearance\n');
        await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await delegator.print('UNREAD_FILTER_STAGE: show cached inbox fixture\n');
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');
        await allMail(driver);
        await delegator.print('UNREAD_FILTER_STAGE: test repeated filter cycles\n');

        for (let cycle = 0; cycle < 3; cycle++) {
          await (await required(driver, 'filter-unread')).click(); await filtered(driver);
          if (cycle === 2) { await capture('top-filtered'); }
          await (await required(driver, 'filter-unread')).click(); await allMail(driver);
        }
        const headerBefore = await (await required(driver, 'filter-unread')).getBounds();
        for (let cycle = 0; cycle < 3; cycle++) {
          await (await required(driver, 'mail-list')).scrollToBottom(12000); await driver.delayMs(200);
          await visibleRow(driver, 'mail-39');
          const headerAfter = await (await required(driver, 'filter-unread')).getBounds();
          expect(Math.abs(headerAfter.top - headerBefore.top) <= 2).assertTrue();
          if (cycle === 0) { await capture('bottom-all'); }
          await (await required(driver, 'filter-unread')).click(); await filtered(driver);
          if (cycle === 2) { await capture('bottom-filtered'); }
          await (await required(driver, 'filter-unread')).click(); await allMail(driver);
        }
        expect(ability.navigationCallCount()).assertEqual(0);
        await (await required(driver, 'filter-unread')).click(); await filtered(driver);
        await (await required(driver, 'remote-mail-mail-00')).click();
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Older unread question');
        expect(await driver.waitForComponent(ON.text('Unread conversation body.'), 5000) !== null).assertTrue();
        for (let attempt = 0; attempt < 30; attempt++) {
          const cached = await store.mail.email(account.id, older.id, true);
          if (cached?.mail.keywords.includes('$seen') && cached.stateDirty === false) { break; }
          await driver.delayMs(100);
        }
        expect((await store.mail.email(account.id, older.id, true))?.mail.keywords.includes('$seen')).assertTrue();
        expect((await store.mail.email(account.id, older.id, true))?.stateDirty).assertFalse();
        expect(ability.navigationCallSummary()).assertEqual('Beta:setKeyword:$seen:true');
        expect(ability.navigationViolationCount()).assertEqual(0);
        await driver.delayMs(400);
        expect(await driver.findComponent(ON.id('remote-mail-mail-00')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('remote-mail-mail-01')) === null).assertTrue();
        await capture('unread-thread-opened');
      } finally {
        await delegator.print('UNREAD_FILTER_STAGE: cleanup synthetic fixture\n');
        try { await ability.hideNavigationFixture(); await driver.delayMs(200); }
        catch (_) { await delegator.print('UNREAD_FILTER_STAGE: cleanup window already unavailable\n'); }
        await store.open(ability.context);
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close(); application.setColorMode(previousMode);
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
