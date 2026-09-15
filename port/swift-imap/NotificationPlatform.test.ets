// One bounded, socket-free OS integration test in the isolated main HAP.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { NotificationPlatform } from '../../../main/ets/mail/notifications/NotificationPlatform';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const delegator = abilityDelegatorRegistry.getAbilityDelegator();
  await delegator.print(`NOTIFICATION_PLATFORM_REQUIRED: ${id}\n`);
  const component = await driver.waitForComponent(ON.id(id), 3000);
  if (component === null) { await delegator.print(`NOTIFICATION_PLATFORM_MISSING: ${id}\n`); }
  expect(component !== null).assertTrue(); return component;
}
async function absent(driver: Driver, id: string): Promise<void> {
  for (let attempt = 0; attempt < 20; attempt++) {
    if (await driver.findComponent(ON.id(id)) === null) { return; }
    await driver.delayMs(50);
  }
  expect(await driver.findComponent(ON.id(id)) === null).assertTrue();
}

async function allowTestNotifications(driver: Driver, ability: EntryAbility): Promise<void> {
  // The promise stays pending while the OS dialog is open. Handle only the
  // permission requested here by this freshly installed synthetic test app.
  let complete = false;
  let granted = false;
  const request = NotificationPlatform.requestEnable(ability.context)
    .then(() => { granted = true; complete = true; }, () => { complete = true; });
  for (let attempt = 0; attempt < 30 && !complete; attempt++) {
    const english = await driver.findComponent(ON.text('Allow'));
    const chinese = english === null ? await driver.findComponent(ON.text('允许')) : null;
    const allow = english === null ? chinese : english;
    if (allow !== null) { await allow.click(); }
    await driver.delayMs(150);
  }
  expect(complete).assertTrue();
  if (complete) { await request; }
  expect(granted).assertTrue();
  expect(await NotificationPlatform.isEnabled()).assertTrue();
}

export default function tests(): void {
  describe('NotificationPlatform', () => {
    it('permission_banner_slot_private_notification_badge_and_background_schedule', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      await delegator.print('NOTIFICATION_PLATFORM_STAGE: bounded emulator unlock and warmup\n');
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
      const notificationId = 740101;
      let passed = false;
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'notification-synthetic-token', 'beta@example.test');
        const inbox = navigationMailbox(); inbox.totalEmails = 1; inbox.unreadEmails = 1;
        const message = navigationMail('Beta', 0, 0, true); message.keywords = [];
        await store.mail.saveBoxes(account.id, [inbox], false);
        await store.mail.saveView(account.id, 'inbox', [message]); await store.mail.saveEmail(account.id, message);
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        await ability.showNavigationFixture();
        expect(await driver.waitForComponent(ON.id('navigation-fixture-marker'), 3000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.id('inbox-title'), 3000) !== null).assertTrue();
        await driver.delayMs(450);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();

        await delegator.print('NOTIFICATION_PLATFORM_STAGE: cached unread dots and visible permission entry\n');
        await required(driver, 'inbox-unread-dot');
        await required(driver, 'enable-inbox-notifications');
        await (await required(driver, 'inbox-account')).click();
        await required(driver, `account-unread-${account.id}`); await driver.pressBack();
        await driver.delayMs(500);
        await (await required(driver, 'open-mailboxes')).click();
        await required(driver, 'mailbox-unread-inbox');
        await (await required(driver, 'remote-box-inbox')).click(); await driver.delayMs(400);
        await store.mail.updateKeyword(account.id, message.id, '$seen', true, true);
        await ability.refreshNavigationUnread(); await absent(driver, 'inbox-unread-dot');
        await store.mail.updateKeyword(account.id, message.id, '$seen', false, true);
        await ability.refreshNavigationUnread(); await required(driver, 'inbox-unread-dot');

        await delegator.print('NOTIFICATION_PLATFORM_STAGE: dismiss foreground banner without leaving composition\n');
        await (await required(driver, 'compose-mail')).click(); await required(driver, 'compose-panel');
        await driver.delayMs(500);
        ability.setNavigationInboxForeground(true); ability.showNavigationBanner(account.id, 1);
        await required(driver, 'new-mail-banner');
        await (await required(driver, 'new-mail-banner-dismiss')).click();
        await absent(driver, 'new-mail-banner'); await required(driver, 'compose-panel');

        await delegator.print('NOTIFICATION_PLATFORM_STAGE: request test-app notification permission\n');
        await allowTestNotifications(driver, ability);
        await NotificationPlatform.ensureSlot();
        const slot = await notificationManager.getSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
        expect(slot.enabled).assertTrue();
        // Some API 22 images return the legacy level field only.
        expect(slot.notificationLevel ?? slot.level).assertEqual(notificationManager.SlotLevel.LEVEL_HIGH);
        await NotificationPlatform.publish(ability.context, notificationId, 'synthetic-account-opaque-7401');
        // This API is scoped by the OS to this application's own notifications.
        const notices = (await notificationManager.getActiveNotifications()).filter(value => value.id === notificationId);
        expect(notices.length).assertEqual(1);
        expect(notices[0].notificationSlotType).assertEqual(notificationManager.SlotType.SOCIAL_COMMUNICATION);
        expect(notices[0].content.notificationContentType).assertEqual(notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT);
        expect(notices[0].content.normal!.title).assertEqual('New mail');
        expect(notices[0].content.normal!.text).assertEqual('Open inbox');
        await NotificationPlatform.cancel(notificationId);
        expect((await notificationManager.getActiveNotifications()).filter(value => value.id === notificationId).length).assertEqual(0);

        await delegator.print('NOTIFICATION_PLATFORM_STAGE: set and clear isolated launcher badge state\n');
        await NotificationPlatform.setUnreadBadge(7);
        expect(await notificationManager.getBadgeNumber()).assertEqual(7);
        await NotificationPlatform.setUnreadBadge(0);
        expect(await notificationManager.getBadgeNumber()).assertEqual(0);

        await delegator.print('NOTIFICATION_PLATFORM_STAGE: register, inspect and remove two-hour persisted work\n');
        await NotificationPlatform.schedule(ability.context, 120);
        const work = await workScheduler.getWorkStatus(7401);
        expect(work.workId).assertEqual(7401);
        expect(work.bundleName).assertEqual('org.thunderbird.harmony.imaptest');
        expect(work.abilityName).assertEqual('MailCheckAbility');
        expect(work.isPersisted).assertTrue(); expect(work.isRepeat).assertTrue();
        expect(work.repeatCycleTime).assertEqual(120 * 60000);
        expect(work.networkType).assertEqual(workScheduler.NetworkType.NETWORK_TYPE_ANY);
        await NotificationPlatform.schedule(ability.context, null);
        expect((await workScheduler.obtainAllWorks()).filter(value => value.workId === 7401).length).assertEqual(0);
        expect((await store.notificationSettings(account.id)).enabled).assertFalse();
        expect(ability.navigationCallCount()).assertEqual(0); expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('NOTIFICATION_PLATFORM_RESULT: unread dots, permission entry, composer-safe banner, OS permission, banner-capable slot, private alert, badge set-clear and persisted schedule passed; account remains off, zero mail service calls\n');
        passed = true;
      } finally {
        if (!passed) {
          // Capture only this isolated synthetic fixture, before hiding it.
          try {
            const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/notification-platform-failure.png');
            await delegator.print(`NOTIFICATION_PLATFORM_FAILURE_SCREEN: exit ${capture.exitCode}\n`);
          } catch (_) { await delegator.print('NOTIFICATION_PLATFORM_FAILURE_SCREEN: capture unavailable\n'); }
        }
        await delegator.print('NOTIFICATION_PLATFORM_STAGE: clear isolated test notification, work and account\n');
        ability.dismissNavigationBanner(); ability.setNavigationInboxForeground(false);
        try { await NotificationPlatform.cancel(notificationId); } catch (_) {}
        try { await NotificationPlatform.setUnreadBadge(0); } catch (_) {}
        try { await NotificationPlatform.schedule(ability.context, null); } catch (_) {}
        try { await ability.hideNavigationFixture(); await driver.delayMs(150); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
