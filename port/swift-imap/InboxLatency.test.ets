// Actual ArkUI with a synthetic transport. No provider connection is created.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { navigationAccount, navigationMailbox, navigationSentMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 10000);
  expect(value !== null).assertTrue(); return value;
}
async function pull(driver: Driver, density: number): Promise<void> {
  const bounds = await (await required(driver, 'mail-refresh')).getBounds();
  const x = Math.round((bounds.left + bounds.right) / 2);
  await driver.swipe(x, Math.round(bounds.top + 30 * density), x,
    Math.round(Math.min(bounds.bottom - 30 * density, bounds.top + 310 * density)), 600);
}
async function settledInbox(driver: Driver, density: number): Promise<void> {
  // The settled search height proves refresh ownership was released. Requiring
  // the first row at List's top also rejects a retained native pull offset.
  let previousTop = -1, stable = 0;
  for (let attempt = 0; attempt < 50; attempt++) {
    const search = await driver.findComponent(ON.id('inbox-search-reveal'));
    if (search !== null) {
      const shown = await search.getBounds();
      const row = await (await required(driver, 'remote-mail-mail-00')).getBounds();
      const list = await (await required(driver, 'mail-list')).getBounds();
      if (Math.abs(shown.bottom - shown.top - 56 * density) <= 3 && Math.abs(row.top - list.top) <= 3 &&
        Math.abs(list.top - previousTop) <= 2) { stable++; } else { stable = 0; }
      previousTop = list.top;
      if (stable >= 2) {
        expect(await driver.findComponent(ON.id('connection-loading')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('inbox-loading')) === null).assertTrue();
        await required(driver, 'search-mail'); return;
      }
    }
    await driver.delayMs(120);
  }
  expect(false).assertTrue();
}
function expectPending(ability: EntryAbility, calls: string): void {
  expect(ability.navigationPendingSentPages()).assertEqual(1);
  expect(ability.navigationPendingPages()).assertEqual(0);
  expect(ability.navigationCallSummary()).assertEqual(calls);
  expect(ability.navigationClientCount()).assertEqual(1);
  expect(ability.navigationViolationCount()).assertEqual(0);
}

export default function tests(): void {
  describe('InboxLatency', () => {
    it('inbox_refresh_finishes_and_repeated_pulls_share_pending_sent_work', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator(), driver = Driver.create();
      await driver.wakeUpDisplay();
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
        await required(driver, 'inbox-latency-fixture-marker');
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/inbox-latency-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        ability.resetNavigationFixtureState(); ability.enableNavigationSentLatency();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'latency-synthetic-token', 'beta@example.test');
        const messages: JmapEmail[] = [];
        for (let index = 0; index < 80; index++) {
          const mail = navigationMail('Beta', index, 0, true); mail.textBody = null; messages.push(mail);
        }
        await store.mail.saveBoxes(account.id, [navigationMailbox(), navigationSentMailbox()], false);
        await store.mail.saveView(account.id, 'inbox', messages);
        await store.mail.saveView(account.id, 'sent', []);
        await store.mail.saveEmail(account.id, navigationMail('Beta', 1, 0, true));
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        ability.setNavigationInboxForeground(true);
        await ability.showInboxLatencyFixture(); await required(driver, 'remote-mail-mail-00');
        // Observe local startup completion via a real enabled swipe action.
        const ready = await (await required(driver, 'remote-mail-mail-00')).getBounds();
        const left = Math.round(ready.left + (ready.right - ready.left) * 0.18);
        const right = Math.round(ready.left + (ready.right - ready.left) * 0.82);
        const y = Math.round((ready.top + ready.bottom) / 2);
        await driver.swipe(left, y, right, y, 600);
        expect(await driver.waitForComponent(ON.id('swipe-read-mail-00').enabled(true), 10000) !== null).assertTrue();
        await driver.swipe(right, y, right - Math.round(80 * density), y, 600); await driver.delayMs(350);
        expect(ability.navigationCallCount()).assertEqual(0); await capture('cached');

        await delegator.print('INBOX_LATENCY_STAGE: immediate Inbox settles while first Sent page remains held\n');
        await pull(driver, density);
        for (let attempt = 0; attempt < 60 && ability.navigationPendingSentPages() === 0; attempt++) { await driver.delayMs(100); }
        let calls = 'Beta:emailPage:inbox,Beta:emailPage:sent';
        await capture('held'); expectPending(ability, calls);
        await settledInbox(driver, density); await capture('settled');
        expectPending(ability, calls);
        expect((await store.mail.view(account.id, 'inbox', true, false))!.emails[0].subject).assertEqual('Beta message 00 revision 1');

        await delegator.print('INBOX_LATENCY_STAGE: a second pull refreshes Inbox without a duplicate Sent request\n');
        await pull(driver, density);
        calls += ',Beta:emailPage:inbox';
        for (let attempt = 0; attempt < 60 && ability.navigationCallSummary() !== calls; attempt++) { await driver.delayMs(100); }
        await capture('repeat'); expectPending(ability, calls);
        await settledInbox(driver, density); await capture('repeat'); expectPending(ability, calls);
        expect((await store.mail.view(account.id, 'inbox', true, false))!.emails[0].subject).assertEqual('Beta message 00 revision 2');

        await (await required(driver, 'remote-mail-mail-01')).click();
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta message 01 revision 2');
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 10000) !== null).assertTrue();
        expectPending(ability, calls); await driver.delayMs(500); await capture('reader');

        // Inject the same foreground bus signal used by the production ability;
        // this is a deterministic lifecycle-path check, not a physical lock test.
        ability.setNavigationInboxForeground(false); ability.requestNavigationInboxUpdate(account.id);
        await driver.delayMs(1200); expectPending(ability, calls);
        ability.releaseNavigationSentPages();
        for (let attempt = 0; attempt < 60 && ability.navigationPendingSentPages() > 0; attempt++) { await driver.delayMs(100); }
        await driver.delayMs(600);
        expect(ability.navigationPendingSentPages()).assertEqual(0);
        expect(ability.navigationCallSummary()).assertEqual(calls);
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta message 01 revision 2');
        expect((await store.mail.email(account.id, 'mail-01', true))!.mail.textBody).assertEqual('Beta cached body');
        expect(ability.navigationViolationCount()).assertEqual(0); await capture('background');
        await delegator.print('INBOX_LATENCY_RESULT: two Inbox pulls settle before one held Sent page; cached reader opens with zero body requests; background signal starts no new work; one client and three page requests\n');
      } catch (error) {
        try { await capture('failure'); } catch (_) {}
        throw error as Error;
      } finally {
        ability.setNavigationInboxForeground(false); ability.releaseNavigationSentPages();
        try { await ability.hideNavigationFixture(); await driver.delayMs(250); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
