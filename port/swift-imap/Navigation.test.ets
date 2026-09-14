// Native UI against an in-memory two-account service; no provider connections.
import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON, Component, Rect, MatchPattern } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { inputMethod } from '@kit.IMEKit';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { CachedEmail } from '../../../main/ets/data/MailCacheModel';
import { NavigationFixtureState, navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import { NavigationTestSession } from '../support/NavigationTestSession';

async function component(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 5000);
  expect(value !== null).assertTrue(); return value;
}
async function searchInput(driver: Driver): Promise<Component> {
  return component(driver, '__SearchField__search-mail');
}
async function listSwipe(driver: Driver, from: number, to: number): Promise<void> {
  const area = await (await component(driver, 'mail-list')).getBounds();
  const x = Math.round((area.left + area.right) / 2), height = area.bottom - area.top;
  await driver.swipe(x, Math.round(area.top + height * from), x, Math.round(area.top + height * to), 700);
  await driver.delayMs(400);
}
async function dismissKeyboard(): Promise<void> {
  // Stop only this test application's text input; Back could close the root UI
  // when clearing the query has already hidden the keyboard with its Search.
  try { await inputMethod.getController().stopInputSession(); } catch (_) {}
}
async function confirmedKeyword(driver: Driver, store: AccountStore, accountId: string, keyword: string): Promise<CachedEmail> {
  for (let attempt = 0; attempt < 30; attempt++) {
    const cached = await store.mail.email(accountId, 'mail-00', true);
    if (cached && cached.stateDirty === false && cached.mail.keywords.includes(keyword)) { return cached; }
    await driver.delayMs(100);
  }
  throw new Error('Acknowledged flag was not saved');
}
async function rowVisible(driver: Driver, id: string): Promise<boolean> {
  const row = await driver.findComponent(ON.id(id));
  if (row === null) { return false; }
  const area: Rect = await (await component(driver, 'mail-list')).getBounds();
  const bounds = await row.getBounds();
  return bounds.bottom > area.top + 4 && bounds.top < area.bottom - 4;
}
async function returnToTop(driver: Driver): Promise<void> {
  for (let attempt = 0; attempt < 24; attempt++) {
    const row = await driver.findComponent(ON.id('remote-mail-mail-00'));
    const area = await (await component(driver, 'mail-list')).getBounds();
    if (row !== null && (await row.getBounds()).top >= area.top - 2 &&
      await driver.findComponent(ON.id('search-mail')) !== null) { return; }
    // A short drag reaches the edge without exceeding the native 80 vp refresh
    // threshold; the later deliberate long pull is the only network refresh.
    await listSwipe(driver, 0.35, 0.45);
  }
  throw new Error('Inbox did not return to the top with search visible');
}

export default function navigationTests(): void {
  describe('AccountNavigationAndSearch', () => {
    it('account_picker_restores_last_account_and_search_only_reveals_at_top', 0, async () => {
      const driver = Driver.create();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability = await NavigationTestSession.acquire();
      let store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/navigation-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        NavigationFixtureState.reset();
        for (const account of await store.list()) { await store.remove(account.id); }
        const alpha = await store.add('https://alpha.example.test/session', navigationAccount('Alpha'), 'alpha-synthetic-token', 'alpha@example.test');
        const beta = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'beta-synthetic-token', 'beta@example.test');
        for (const saved of [alpha, beta]) {
          const label = saved.id === alpha.id ? 'Alpha' : 'Beta';
          const cached: JmapEmail[] = [];
          for (let index = 0; index < 80; index++) { cached.push(navigationMail(label, index, 0, true)); }
          await store.mail.saveBoxes(saved.id, [navigationMailbox()]);
          await store.mail.saveView(saved.id, 'inbox', cached);
          await store.mail.saveEmail(saved.id, navigationMail(label, 0, 0, true));
        }
        expect(await store.lastVisitedAccount() === null).assertTrue();
        await AppLanguage.set(ability.context, 'en');
        await ability.showNavigationFixture();
        expect(await driver.waitForComponent(ON.text('Alpha cached message 00'), 10000) !== null).assertTrue();
        expect(await (await component(driver, 'inbox-account-label')).getText()).assertEqual('alpha@example.test');
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        await capture('alpha');
        await (await component(driver, 'inbox-account')).click();
        await component(driver, 'account-picker');
        await component(driver, `switch-account-${alpha.id}`);
        await component(driver, `switch-account-${beta.id}`);
        await driver.delayMs(350); await capture('picker');
        NavigationFixtureState.betaOffline = true;
        await (await component(driver, `switch-account-${beta.id}`)).click();
        expect(await driver.waitForComponent(ON.text('Beta cached message 00').within(ON.id('mail-list')), 10000) !== null).assertTrue();
        expect(await (await component(driver, 'inbox-account-label')).getText()).assertEqual('beta@example.test');
        expect(await driver.findComponent(ON.text('Alpha', MatchPattern.CONTAINS).within(ON.id('mail-list'))) === null).assertTrue();
        expect((await store.lastVisitedAccount())?.id).assertEqual(beta.id);
        expect((await store.mail.email(beta.id, 'mail-00'))?.mail.textBody).assertEqual('Beta cached body');
        expect((await store.mail.email(alpha.id, 'mail-00'))?.mail.textBody).assertEqual('Alpha cached body');
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        await capture('beta-cached');
        await (await component(driver, 'remote-mail-mail-00')).click();
        expect(await (await component(driver, 'reader-subject')).getText()).assertEqual('Beta cached message 00');
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 5000) !== null).assertTrue();
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        await capture('beta-offline-reader');
        await driver.pressBack();
        expect(await driver.waitForComponent(ON.text('Beta cached message 00').within(ON.id('mail-list')), 5000) !== null).assertTrue();

        // Recreate both presentation and storage handles, retaining only persisted data.
        await ability.hideNavigationFixture(); await driver.delayMs(300);
        await store.close(); store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
        expect((await store.lastVisitedAccount())?.id).assertEqual(beta.id);
        await ability.showNavigationFixture();
        expect(await driver.waitForComponent(ON.text('Beta cached message 00'), 10000) !== null).assertTrue();
        expect(await (await component(driver, 'inbox-account-label')).getText()).assertEqual('beta@example.test');
        expect(NavigationFixtureState.alphaPages).assertEqual(0);
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        expect(NavigationFixtureState.created.join(',')).assertEqual('Alpha,Beta,Beta');
        expect(await driver.findComponent(ON.text('Alpha', MatchPattern.CONTAINS).within(ON.id('mail-list'))) === null).assertTrue();
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        await capture('beta-restored');

        await listSwipe(driver, 0.85, 0.20); await listSwipe(driver, 0.85, 0.20);
        expect(await rowVisible(driver, 'remote-mail-mail-00')).assertFalse();
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        await listSwipe(driver, 0.35, 0.52);
        expect(await rowVisible(driver, 'remote-mail-mail-00')).assertFalse();
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        await capture('search-middle');
        await returnToTop(driver);
        expect(await rowVisible(driver, 'remote-mail-mail-00')).assertTrue();
        await capture('search-top');
        // Search exposes its editable value on the native SearchField child.
        // Verify a narrow result first so a successful input API alone cannot pass.
        await delegator.executeShellCommand('uitest dumpLayout -p /data/local/tmp/navigation-search-before.json');
        await (await searchInput(driver)).click();
        await (await searchInput(driver)).inputText('Beta cached message 00');
        await driver.delayMs(300); await capture('search-input');
        await delegator.executeShellCommand('uitest dumpLayout -p /data/local/tmp/navigation-search-after.json');
        expect(await (await searchInput(driver)).getOriginalText()).assertEqual('Beta cached message 00');
        expect(await driver.findComponent(ON.id('remote-mail-mail-00')) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('remote-mail-mail-01')) === null).assertTrue();
        await (await searchInput(driver)).inputText('Beta');
        await driver.delayMs(300); await dismissKeyboard(); await driver.delayMs(300);
        await capture('search-query');
        expect(await (await searchInput(driver)).getOriginalText()).assertEqual('Beta');
        await listSwipe(driver, 0.85, 0.20); await listSwipe(driver, 0.85, 0.20);
        expect(await rowVisible(driver, 'remote-mail-mail-00')).assertFalse();
        expect(await (await searchInput(driver)).getOriginalText()).assertEqual('Beta');
        await capture('search-query');
        await (await searchInput(driver)).inputText('');
        await driver.delayMs(300); await dismissKeyboard(); await driver.delayMs(300);
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        await returnToTop(driver);
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        NavigationFixtureState.betaOffline = false;
        const before = NavigationFixtureState.betaPages;
        await listSwipe(driver, 0.15, 0.90);
        expect(await driver.waitForComponent(ON.text(`Beta message 00 revision ${before + 1}`), 10000) !== null).assertTrue();
        expect(NavigationFixtureState.betaPages).assertEqual(before + 1);
        expect(await driver.findComponent(ON.id('connection-error')) === null).assertTrue();
        expect(NavigationFixtureState.violations.length).assertEqual(0);
        expect((await store.lastVisitedAccount())?.id).assertEqual(beta.id);
        await capture('refreshed');

        // Acknowledged row flags and automatic marking as read must update only
        // mutable metadata. The already-downloaded body stays usable throughout.
        const beforeFlags = (await store.mail.email(beta.id, 'mail-00'))!;
        expect(beforeFlags.mail.keywords.includes('$seen')).assertFalse();
        expect(beforeFlags.mail.textBody).assertEqual('Beta cached body');
        const beforeFlagCalls = NavigationFixtureState.calls.length;
        const rowBounds = await (await component(driver, 'remote-mail-mail-00')).getBounds();
        const rowY = Math.round((rowBounds.top + rowBounds.bottom) / 2);
        await driver.swipe(Math.round(rowBounds.left + (rowBounds.right - rowBounds.left) * 0.85), rowY,
          Math.round(rowBounds.left + (rowBounds.right - rowBounds.left) * 0.25), rowY, 600);
        await (await driver.waitForComponent(ON.id('swipe-star-mail-00').enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.id('remote-star-mail-00'), 5000) !== null).assertTrue();
        expect(await driver.waitForIdle(300, 5000)).assertTrue();
        const starred = await confirmedKeyword(driver, store, beta.id, '$flagged');
        expect(starred.stateDirty).assertFalse();
        expect(starred.mail.keywords.includes('$flagged')).assertTrue();
        expect(starred.mail.keywords.includes('$seen')).assertFalse();
        expect(starred.mail.textBody).assertEqual(beforeFlags.mail.textBody);
        expect(starred.savedAt).assertEqual(beforeFlags.savedAt);
        expect(starred.bodySavedAt).assertEqual(beforeFlags.bodySavedAt);
        expect(starred.bodyDecoderRevision).assertEqual(beforeFlags.bodyDecoderRevision);
        expect(NavigationFixtureState.calls.slice(beforeFlagCalls).join(',')).assertEqual('Beta:setKeyword:$flagged:true');
        await (await driver.waitForComponent(ON.id('remote-mail-mail-00').enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Beta cached body').within(ON.id('reader-scroll')), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.id('reply-mail').enabled(true), 5000) !== null).assertTrue();
        expect(await driver.waitForIdle(300, 5000)).assertTrue();
        const seen = await confirmedKeyword(driver, store, beta.id, '$seen');
        expect(seen.stateDirty).assertFalse();
        expect(seen.mail.keywords.includes('$flagged')).assertTrue();
        expect(seen.mail.keywords.includes('$seen')).assertTrue();
        expect(seen.mail.textBody).assertEqual(beforeFlags.mail.textBody);
        expect(seen.savedAt).assertEqual(beforeFlags.savedAt);
        expect(seen.bodySavedAt).assertEqual(beforeFlags.bodySavedAt);
        expect(seen.bodyDecoderRevision).assertEqual(beforeFlags.bodyDecoderRevision);
        expect((await store.mail.email(alpha.id, 'mail-00'))?.mail.keywords.includes('$flagged')).assertFalse();
        expect(NavigationFixtureState.calls.slice(beforeFlagCalls).join(',')).assertEqual('Beta:setKeyword:$flagged:true,Beta:setKeyword:$seen:true');
        expect(NavigationFixtureState.violations.length).assertEqual(0);

      } finally {
        await ability.hideNavigationFixture(); await driver.delayMs(200);
        await store.open(ability.context);
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
      }
    });
  });
}
