// Bounded synthetic gesture/layout observation in the isolated main HAP.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
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
async function noExtraSpinner(driver: Driver): Promise<void> {
  expect(await driver.findComponent(ON.id('connection-loading')) === null).assertTrue();
  expect(await driver.findComponent(ON.id('inbox-loading')) === null).assertTrue();
  // Some native Refresh versions do not expose their internal indicator node.
  const indicators = await driver.findComponents(ON.type('LoadingProgress'));
  expect(indicators.length <= 1).assertTrue();
  await abilityDelegatorRegistry.getAbilityDelegator().print(`INBOX_PRESENTATION_SPINNERS: exposed ${indicators.length}\n`);
}
async function searchHidden(driver: Driver): Promise<void> {
  const wrapper = await driver.findComponent(ON.id('inbox-search-reveal'));
  if (wrapper !== null) {
    const bounds = await wrapper.getBounds(); expect(bounds.bottom - bounds.top <= 1).assertTrue();
  }
}
async function searchShown(driver: Driver, density: number): Promise<Rect> {
  const wrapper = await required(driver, 'inbox-search-reveal');
  const bounds = await wrapper.getBounds();
  expect(Math.abs(bounds.bottom - bounds.top - 56 * density) <= 3).assertTrue();
  await required(driver, 'search-mail'); return bounds;
}

export default function tests(): void {
  describe('InboxPresentation', () => {
    it('held_pull_refresh_retains_rows_with_one_indicator_and_search_settles_at_top', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync(), density = screen.densityPixels;
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
      const capture = async (name: string): Promise<void> => {
        await required(driver, 'navigation-fixture-marker');
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/inbox-presentation-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'presentation-synthetic-token', 'beta@example.test');
        const messages: JmapEmail[] = [];
        for (let index = 0; index < 80; index++) { messages.push(navigationMail('Beta', index, 0, true)); }
        await store.mail.saveBoxes(account.id, [navigationMailbox()], false);
        await store.mail.saveView(account.id, 'inbox', messages);
        await store.mail.saveEmail(account.id, messages[0]); await store.mail.saveEmail(account.id, messages[1]);
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');
        const beforeRow = await (await required(driver, 'remote-mail-mail-00')).getBounds();
        await driver.delayMs(500); await searchHidden(driver); await noExtraSpinner(driver);
        expect(ability.navigationCallCount()).assertEqual(0);
        const refresh = await (await required(driver, 'mail-refresh')).getBounds();

        await delegator.print('INBOX_PRESENTATION_STAGE: held pull refresh preserves rows and header geometry\n');
        ability.holdNavigationPages(true);
        const x = Math.round((refresh.left + refresh.right) / 2);
        await driver.swipe(x, Math.round(refresh.top + 30 * density),
          x, Math.round(Math.min(refresh.bottom - 30 * density, refresh.top + 310 * density)), 600);
        for (let attempt = 0; attempt < 35 && ability.navigationPendingPages() === 0; attempt++) { await driver.delayMs(80); }
        expect(ability.navigationPendingPages()).assertEqual(1);
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage');
        await noExtraSpinner(driver); await searchHidden(driver);
        const pendingRow = await (await required(driver, 'remote-mail-mail-00')).getBounds();
        expect(Math.abs(pendingRow.bottom - pendingRow.top - (beforeRow.bottom - beforeRow.top)) <= 3).assertTrue();
        const pendingRefresh = await (await required(driver, 'mail-refresh')).getBounds();
        expect(Math.abs(pendingRefresh.top - refresh.top) <= 3).assertTrue();
        expect((await store.mail.view(account.id, 'inbox', true))!.emails.length).assertEqual(80);
        await capture('pending');
        ability.holdNavigationPages(false);
        for (let attempt = 0; attempt < 45; attempt++) {
          const cached = await store.mail.view(account.id, 'inbox', true);
          if (cached?.emails[0]?.subject === 'Beta message 00 revision 1') { break; }
          await driver.delayMs(80);
        }
        expect((await store.mail.view(account.id, 'inbox', true))!.emails[0].subject).assertEqual('Beta message 00 revision 1');
        await driver.delayMs(850); await noExtraSpinner(driver);
        const shown = await searchShown(driver, density); await capture('after');

        await delegator.print('INBOX_PRESENTATION_STAGE: search collapses away from top and returns to the same settled bounds\n');
        const list = await (await required(driver, 'mail-list')).getBounds();
        await driver.swipe(x, Math.round(list.bottom - 50 * density), x, Math.round(list.top + 80 * density), 800);
        await driver.delayMs(1000); await searchHidden(driver); await capture('scrolled');
        await (await required(driver, 'mail-list')).scrollToTop(1000);
        await driver.delayMs(850);
        const returned = await searchShown(driver, density);
        expect(Math.abs(returned.top - shown.top) <= 3 && Math.abs(returned.bottom - shown.bottom) <= 3).assertTrue();
        await capture('returned');
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage');

        await delegator.print('INBOX_PRESENTATION_STAGE: scroll and cached reader remain usable while a second refresh is pending\n');
        ability.holdNavigationPages(true);
        const secondRefresh = await (await required(driver, 'mail-refresh')).getBounds();
        await driver.swipe(x, Math.round(secondRefresh.top + 30 * density),
          x, Math.round(Math.min(secondRefresh.bottom - 30 * density, secondRefresh.top + 310 * density)), 600);
        for (let attempt = 0; attempt < 35 && ability.navigationPendingPages() === 0; attempt++) { await driver.delayMs(80); }
        expect(ability.navigationPendingPages()).assertEqual(1);
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage,Beta:emailPage');
        const heldFirst = await (await required(driver, 'remote-mail-mail-00')).getBounds();
        const heldList = await (await required(driver, 'mail-list')).getBounds();
        await driver.swipe(x, Math.round(heldList.bottom - 50 * density), x, Math.round(heldList.top + 80 * density), 800);
        await driver.delayMs(400);
        const scrolledFirst = await driver.findComponent(ON.id('remote-mail-mail-00'));
        if (scrolledFirst !== null) {
          expect((await scrolledFirst.getBounds()).top < heldFirst.top - 20 * density).assertTrue();
        }
        expect(ability.navigationPendingPages()).assertEqual(1);
        await capture('held-scrolled');
        await (await required(driver, 'mail-list')).scrollToTop(1000);
        await driver.delayMs(400);
        // mail-01 is already seen, so opening its retained body requires no
        // protocol operation. The held header response must remain unresolved.
        await (await required(driver, 'remote-mail-mail-01')).click();
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta message 01 revision 1');
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 4000) !== null).assertTrue();
        expect(ability.navigationPendingPages()).assertEqual(1);
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage,Beta:emailPage');
        await driver.delayMs(650); await capture('held-reader');
        ability.holdNavigationPages(false);
        for (let attempt = 0; attempt < 35 && ability.navigationPendingPages() !== 0; attempt++) { await driver.delayMs(80); }
        expect(ability.navigationPendingPages()).assertEqual(0);
        await driver.delayMs(400);
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta message 01 revision 1');
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 4000) !== null).assertTrue();
        expect((await store.mail.view(account.id, 'inbox', true))!.emails[0].subject).assertEqual('Beta message 00 revision 1');
        await capture('released-reader');

        if (screen.width / density >= 760) {
          const inbox = await (await required(driver, 'mail-list')).getBounds();
          const reader = await (await required(driver, 'reader-scroll')).getBounds();
          expect(inbox.right <= reader.left + 2).assertTrue();
          expect(reader.right - reader.left >= 350 * density).assertTrue();
          await capture('split');
          await delegator.print('INBOX_PRESENTATION_STAGE: tablet side-by-side inbox and cached reader preserved\n');
        }
        expect(ability.navigationCallSummary()).assertEqual('Beta:emailPage,Beta:emailPage');
        expect(ability.navigationViolationCount()).assertEqual(0);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();
        await delegator.print('INBOX_PRESENTATION_RESULT: held native refresh retains 80 rows without extra app spinners; search settles hidden away and visible at top; two synthetic Inbox pages; scrolling and cached reading work before release; late refresh preserves reader; no bodies or other mail requests\n');
      } finally {
        ability.holdNavigationPages(false);
        try { await ability.hideNavigationFixture(); await driver.delayMs(200); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
