// Synthetic persisted count/OS badge gate. No mail service is started.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { notificationManager } from '@kit.NotificationKit';
import { Driver, ON } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NotificationPlatform } from '../../../main/ets/mail/notifications/NotificationPlatform';
import { MailBadgeService } from '../../../main/ets/mail/notifications/MailBadgeService';
import { navigationAccount } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function allowTestNotifications(driver: Driver, ability: EntryAbility): Promise<void> {
  let complete = false, granted = false;
  const request = NotificationPlatform.requestEnable(ability.context)
    .then(() => { granted = true; complete = true; }, () => { complete = true; });
  for (let attempt = 0; attempt < 30 && !complete; attempt++) {
    const english = await driver.findComponent(ON.text('Allow'));
    const allow = english === null ? await driver.findComponent(ON.text('允许')) : english;
    if (allow !== null) { await allow.click(); }
    await driver.delayMs(150);
  }
  expect(complete).assertTrue();
  if (complete) { await request; }
  expect(granted).assertTrue();
}

export default function tests(): void {
  describe('UnreadBadge', () => {
    it('persisted_enabled_account_totals_survive_publication_and_clear_on_mute', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
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
      const store = new AccountStore('unread_badge_test.db'); await store.open(ability.context);
      const notificationId = 740111;
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await delegator.print('UNREAD_BADGE_STAGE: isolated notification permission and synthetic saved accounts\n');
        await allowTestNotifications(driver, ability);
        const first = await store.add('https://one.example.test/session', navigationAccount('One'), 'synthetic-token-one', 'one@example.test');
        const second = await store.add('https://two.example.test/session', navigationAccount('Two'), 'synthetic-token-two', 'two@example.test');
        const muted = await store.add('https://muted.example.test/session', navigationAccount('Muted'), 'synthetic-token-muted', 'muted@example.test');
        for (const account of [first, second, muted]) { await store.setNotifications(account.id, true); }
        const firstGuard = await store.badges.beginCheck(first.id);
        expect(firstGuard !== null).assertTrue();
        expect(firstGuard?.revision).assertEqual(1);
        expect(firstGuard?.settingsRevision).assertEqual((await store.notificationSettings(first.id)).revision);
        await store.badges.record(first.id, firstGuard, 137, 'inbox', Date.now());
        const secondGuard = await store.badges.beginCheck(second.id);
        expect(secondGuard !== null).assertTrue();
        await store.badges.record(second.id, secondGuard, 8, 'inbox', Date.now());
        const mutedGuard = await store.badges.beginCheck(muted.id);
        expect(mutedGuard !== null).assertTrue();
        await store.badges.record(muted.id, mutedGuard, 900, 'inbox', Date.now());
        await delegator.print('UNREAD_BADGE_STAGE: guards recorded; checking exact total before close\n');
        expect(await store.badges.total()).assertEqual(1045);
        await store.setNotifications(muted.id, false);
        expect(await store.badges.total()).assertEqual(145);
        await delegator.print('UNREAD_BADGE_STAGE: correct before close; reopening synthetic storage\n');
        await store.close(); await store.open(ability.context);
        expect(await store.badges.total()).assertEqual(145);
        await delegator.print('UNREAD_BADGE_STAGE: persisted total 145 excludes muted account 900\n');
        await MailBadgeService.refresh(store);
        expect(await notificationManager.getBadgeNumber()).assertEqual(145);

        await NotificationPlatform.publish(ability.context, notificationId, first.id);
        expect(await notificationManager.getBadgeNumber()).assertEqual(145);
        await NotificationPlatform.cancel(notificationId);
        await delegator.print('UNREAD_BADGE_STAGE: notification publication preserves full count\n');

        await store.setNotifications(first.id, false); await MailBadgeService.refresh(store);
        expect(await notificationManager.getBadgeNumber()).assertEqual(8);
        await store.setNotifications(second.id, false); await MailBadgeService.refresh(store);
        expect(await notificationManager.getBadgeNumber()).assertEqual(0);
        const other = new AccountStore('unread_badge_test.db'); await other.open(ability.context);
        try {
          const now = Date.now();
          expect(await store.notifications.acquire('synthetic-first', now)).assertTrue();
          expect(await other.notifications.acquire('synthetic-other', now)).assertFalse();
          await other.notifications.release('synthetic-other');
          expect(await other.notifications.acquire('synthetic-other', now)).assertFalse();
          await store.notifications.release('synthetic-first');
          expect(await other.notifications.acquire('synthetic-other', now)).assertTrue();
          await other.notifications.release('synthetic-other');
          await delegator.print('UNREAD_BADGE_STAGE: committed notification lease acquire, contention and release passed\n');
        } finally {
          await store.notifications.release('synthetic-first');
          await other.notifications.release('synthetic-other'); await other.close();
        }
        expect(ability.navigationCallCount()).assertEqual(0);
        expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('UNREAD_BADGE_RESULT: persisted 137 plus 8 excludes muted 900; OS badge 145 survives publication, then 8 and 0 after muting; zero mail service calls\n');
      } finally {
        try { await NotificationPlatform.cancel(notificationId); } catch (_) {}
        try { await NotificationPlatform.setUnreadBadge(0); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
