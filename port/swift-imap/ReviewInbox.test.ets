// A held synthetic page separates interaction correctness from server speed.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component, Rect } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail, JmapKeyword } from '../../../main/ets/mail/jmap/JmapClient';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 15000);
  expect(value !== null).assertTrue(); return value;
}
async function checkHeld(ability: EntryAbility, calls: string): Promise<void> {
  expect(ability.navigationPendingPages()).assertEqual(1);
  expect(ability.navigationCallSummary()).assertEqual(calls);
  expect(ability.navigationClientCount()).assertEqual(1);
  expect(ability.navigationViolationCount()).assertEqual(0);
}
async function confirmed(store: AccountStore, accountId: string, keyword: JmapKeyword, driver: Driver): Promise<void> {
  for (let attempt = 0; attempt < 60; attempt++) {
    const cached = await store.mail.email(accountId, 'mail-00', true);
    if (cached?.mail.keywords.includes(keyword) && cached.stateDirty === false) { return; }
    await driver.delayMs(100);
  }
  expect(false).assertTrue();
}
interface RowAnchor { id: string; index: number; bounds: Rect; }
interface RowSnapshot { list: Rect; rows: RowAnchor[]; }
async function settledRows(driver: Driver): Promise<RowSnapshot> {
  let previous: RowSnapshot | null = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    const list = await (await required(driver, 'mail-list')).getBounds();
    const rows: RowAnchor[] = [];
    for (const component of await driver.findComponents(ON.type('ListItem').within(ON.id('mail-list')))) {
      const id = await component.getId(), match = /^remote-mail-mail-(\d+)$/.exec(id);
      if (!match) { continue; }
      const bounds = await component.getBounds();
      if (bounds.bottom > list.top + 1 && bounds.top < list.bottom - 1) {
        rows.push({ id: id, index: Number(match[1]), bounds: bounds });
      }
    }
    rows.sort((a: RowAnchor, b: RowAnchor) => a.bounds.top - b.bounds.top);
    if (rows.length > 0 && previous && previous.rows.length > 0 && rows[0].id === previous.rows[0].id &&
      Math.abs(rows[0].bounds.top - previous.rows[0].bounds.top) <= 2 && Math.abs(list.top - previous.list.top) <= 2) {
      return { list: list, rows: rows };
    }
    previous = { list: list, rows: rows }; await driver.delayMs(120);
  }
  expect(false).assertTrue(); return previous!;
}

export default function tests(): void {
  describe('ReviewInbox', () => {
    it('two_thousand_cached_headers_keep_gestures_actions_and_reader_usable_during_refresh', 0, async () => {
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
        await required(driver, 'review-inbox-fixture-marker');
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/review-inbox-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'review-synthetic-token', 'beta@example.test');
        const messages: JmapEmail[] = [];
        for (let index = 0; index < 2000; index++) {
          const mail = navigationMail('Beta', index, 0, true); mail.textBody = null;
          if (index === 0) { mail.keywords = []; }
          messages.push(mail);
        }
        const box = navigationMailbox(); box.totalEmails = messages.length; box.unreadEmails = 1;
        await delegator.print('REVIEW_INBOX_STAGE: seed 2000 headers and two cached bodies\n');
        await store.mail.saveBoxes(account.id, [box], false); await store.mail.saveView(account.id, 'inbox', messages);
        const actionMail = navigationMail('Beta', 0, 0, true); actionMail.keywords = [];
        await store.mail.saveEmail(account.id, actionMail);
        await store.mail.saveEmail(account.id, navigationMail('Beta', 1, 0, true));
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        await ability.showReviewInboxFixture(); await required(driver, 'remote-mail-mail-00');
        await driver.delayMs(500);
        expect(ability.navigationCallCount()).assertEqual(0); expect(ability.navigationClientCount()).assertEqual(1);
        expect((await store.mail.view(account.id, 'inbox', true, false))!.emails.length).assertEqual(2000);
        // Cached rows can appear before the final local conversation index has
        // drained. Observe an enabled action instead of guessing startup time.
        const readyRow = await (await required(driver, 'remote-mail-mail-00')).getBounds();
        const readyLeft = Math.round(readyRow.left + (readyRow.right - readyRow.left) * 0.18);
        const readyRight = Math.round(readyRow.left + (readyRow.right - readyRow.left) * 0.82);
        const readyY = Math.round((readyRow.top + readyRow.bottom) / 2);
        await driver.swipe(readyLeft, readyY, readyRight, readyY, 600);
        expect(await driver.waitForComponent(ON.id('swipe-read-mail-00').enabled(true), 15000) !== null).assertTrue();
        await driver.swipe(readyRight, readyY, readyRight - Math.round(80 * density), readyY, 600); await driver.delayMs(350);
        await capture('cached');
        const exposed = await driver.findComponents(ON.type('ListItem').within(ON.id('mail-list')));
        await delegator.print(`REVIEW_INBOX_OBSERVATION: accessibility exposes ${exposed.length} ListItems; this is not a native construction counter\n`);

        ability.holdNavigationPages(true);
        const refresh = await (await required(driver, 'mail-refresh')).getBounds();
        const x = Math.round((refresh.left + refresh.right) / 2);
        await driver.swipe(x, Math.round(refresh.top + 30 * density),
          x, Math.round(Math.min(refresh.bottom - 30 * density, refresh.top + 310 * density)), 600);
        for (let attempt = 0; attempt < 60 && ability.navigationPendingPages() === 0; attempt++) { await driver.delayMs(100); }
        let calls = 'Beta:emailPage'; await checkHeld(ability, calls);
        expect(await driver.findComponent(ON.id('connection-loading')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('inbox-loading')) === null).assertTrue();
        await capture('held');

        await delegator.print('REVIEW_INBOX_STAGE: actual upward and downward drags away from the refresh edge\n');
        // Two substantial upward gestures first consume the native pull offset
        // and then move into the list. A tiny edge drag measures Refresh, not List.
        for (let gesture = 0; gesture < 2; gesture++) {
          const list = await (await required(driver, 'mail-list')).getBounds();
          await driver.swipe(x, Math.round(list.top + (list.bottom - list.top) * 0.85),
            x, Math.round(list.top + (list.bottom - list.top) * 0.2), 600);
          await capture('up'); await checkHeld(ability, calls);
          await settledRows(driver);
        }
        const upward = await settledRows(driver); await capture('up');
        await delegator.print(`REVIEW_INBOX_SCROLL: upward first row ${upward.rows[0].index}, list ${JSON.stringify(upward.list)}\n`);
        expect(upward.rows[0].index >= 2).assertTrue();
        const anchor = upward.rows.find(row => row.bounds.top >= upward.list.top + 2 &&
          row.bounds.bottom < upward.list.top + (upward.list.bottom - upward.list.top) * 0.6);
        expect(anchor !== undefined).assertTrue();
        const startY = Math.round(upward.list.top + (upward.list.bottom - upward.list.top) * 0.25);
        const distance = Math.round(Math.min(180 * density, (upward.list.bottom - upward.list.top) * 0.35));
        await driver.swipe(x, startY, x, startY + distance, 600);
        await capture('down');
        const downRows = await settledRows(driver);
        const downward = await (await required(driver, anchor!.id)).getBounds();
        await capture('down');
        await delegator.print(`REVIEW_INBOX_SCROLL: ${anchor!.id} top ${anchor!.bounds.top} to ${downward.top}, list top ${upward.list.top} to ${downRows.list.top}\n`);
        // Track the same content node while the container stays in place. This
        // cannot pass merely because the search header or pull indicator moved.
        expect(Math.abs(downRows.list.top - upward.list.top) <= 3).assertTrue();
        expect(downward.top > anchor!.bounds.top + 20 * density).assertTrue();
        await checkHeld(ability, calls);
        await (await required(driver, 'mail-list')).scrollToTop(1000); await driver.delayMs(350);

        for (const keyword of ['$seen', '$flagged'] as JmapKeyword[]) {
          const row = await (await required(driver, 'remote-mail-mail-00')).getBounds();
          const left = Math.round(row.left + (row.right - row.left) * 0.18);
          const right = Math.round(row.left + (row.right - row.left) * 0.82), y = Math.round((row.top + row.bottom) / 2);
          await driver.swipe(keyword === '$seen' ? left : right, y, keyword === '$seen' ? right : left, y, 600);
          await driver.delayMs(300);
          const action = await driver.waitForComponent(ON.id(`swipe-${keyword === '$seen' ? 'read' : 'star'}-mail-00`).enabled(true), 15000);
          expect(action !== null).assertTrue();
          expect(await action.isEnabled()).assertTrue(); await action.click();
          calls += `,Beta:setKeyword:${keyword}:true`;
          await confirmed(store, account.id, keyword, driver); await driver.delayMs(350);
          await checkHeld(ability, calls);
          expect(await driver.findComponent(ON.id('reader-scroll')) === null).assertTrue();
        }
        await required(driver, 'remote-star-mail-00'); await capture('actions');
        await delegator.print('REVIEW_INBOX_STAGE: one read and one star acknowledgement before header release\n');

        await (await required(driver, 'remote-mail-mail-01')).click();
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta cached message 01');
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 15000) !== null).assertTrue();
        await checkHeld(ability, calls); await driver.delayMs(500); await capture('reader');
        ability.holdNavigationPages(false);
        for (let attempt = 0; attempt < 60 && ability.navigationPendingPages() !== 0; attempt++) { await driver.delayMs(100); }
        expect(ability.navigationPendingPages()).assertEqual(0); await driver.delayMs(500);
        expect(await (await required(driver, 'reader-subject')).getText()).assertEqual('Beta cached message 01');
        const cached = await store.mail.email(account.id, 'mail-00', true);
        expect(cached?.mail.keywords.includes('$seen')).assertTrue(); expect(cached?.mail.keywords.includes('$flagged')).assertTrue();
        expect(cached?.mail.textBody).assertEqual('Beta cached body');
        expect((await store.mail.view(account.id, 'inbox', true, false))!.emails.length).assertEqual(2000);
        expect(ability.navigationCallSummary()).assertEqual(calls); expect(ability.navigationClientCount()).assertEqual(1);
        expect(ability.navigationViolationCount()).assertEqual(0); expect((await store.notificationSettings(account.id)).enabled).assertFalse();
        await capture('released');
        await delegator.print('REVIEW_INBOX_RESULT: 2000 cached headers; upward and downward drags, read and star actions, and cached reader succeed before page release; one client, one page, two flag operations, zero body or other requests; late page preserves reader, flags and cache\n');
      } catch (error) {
        try { await capture('failure'); } catch (_) {}
        throw error as Error;
      } finally {
        ability.holdNavigationPages(false); ability.holdNavigationKeywords(false);
        try { await ability.hideNavigationFixture(); await driver.delayMs(200); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
