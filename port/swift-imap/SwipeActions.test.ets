// Isolated cached synthetic mail; no network, production account or global UI setting.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component, Rect } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapKeyword } from '../../../main/ets/mail/jmap/JmapClient';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

interface ActionStep { keyword: JmapKeyword; enabled: boolean; point: string; held: boolean; }
async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 4000);
  expect(value !== null).assertTrue(); return value;
}
async function inboxOnly(driver: Driver): Promise<void> {
  await required(driver, 'navigation-fixture-marker'); await required(driver, 'mail-list');
  expect(await driver.findComponent(ON.id('reader-scroll')) === null).assertTrue();
  expect(await driver.findComponent(ON.id('reader-subject')) === null).assertTrue();
}
export default function tests(emulator: boolean = false): void {
  describe('SwipeActions', () => {
    it('read_and_star_center_edge_taps_dispatch_once_without_opening_reader', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      await delegator.print(`SWIPE_ACTION_STAGE: wake synthetic ${emulator ? 'emulator' : 'device'} test surface\n`);
      const driver = Driver.create(); await driver.wakeUpDisplay();
      // A freshly booted bounded emulator may still show its synthetic lock screen.
      // Keep the user's physical-device and boundary-view settings untouched.
      if (emulator) {
        await delegator.print('SWIPE_ACTION_STAGE: bounded emulator unlock and five-second warmup\n');
        const screen = display.getDefaultDisplaySync();
        await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
          Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
        await driver.delayMs(5000);
      }
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.print('SWIPE_ACTION_STAGE: start isolated main ability\n');
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      await delegator.print('SWIPE_ACTION_STAGE: wait for rendered synthetic startup page\n');
      expect(await driver.waitForComponent(ON.text('Preparing mail preview'), 5000) !== null).assertTrue();
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        await inboxOnly(driver);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/swipe-actions-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        await delegator.print('SWIPE_ACTION_STAGE: seed isolated cached messages\n');
        ability.resetNavigationFixtureState(); ability.enableRepeatedNavigationKeywords();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'swipe-synthetic-token', 'beta@example.test');
        const mail = navigationMail('Beta', 0, 0, true); mail.keywords = [];
        mail.subject = 'Synthetic swipe action target';
        const neighbor = navigationMail('Beta', 1, 0, true);
        const box = navigationMailbox(); box.totalEmails = 2; box.unreadEmails = 1;
        await store.mail.saveBoxes(account.id, [box], false);
        await store.mail.saveView(account.id, 'inbox', [mail, neighbor]);
        await store.mail.saveEmail(account.id, mail); await store.rememberVisitedAccount(account.id);
        await AppLanguage.set(ability.context, 'en'); application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await delegator.print('SWIPE_ACTION_STAGE: show synthetic inbox\n');
        await ability.showNavigationFixture(); await inboxOnly(driver); await driver.delayMs(350);
        const density = display.getDefaultDisplaySync().densityPixels;
        const steps: ActionStep[] = [
          { keyword: '$seen', enabled: true, point: 'center', held: false },
          { keyword: '$seen', enabled: false, point: 'upper-left', held: true },
          { keyword: '$flagged', enabled: true, point: 'center', held: false },
          { keyword: '$flagged', enabled: false, point: 'lower-right', held: false }
        ];
        const expected: string[] = [];
        for (let index = 0; index < steps.length; index++) {
          const step = steps[index];
          await delegator.print(`SWIPE_ACTION_STAGE: action ${index + 1} ${step.keyword} ${step.enabled} ${step.point}\n`);
          const before = await (await required(driver, 'remote-mail-mail-00')).getBounds();
          const width = before.right - before.left, y = Math.round((before.top + before.bottom) / 2);
          const left = Math.round(before.left + width * 0.18), right = Math.round(before.left + width * 0.82);
          ability.holdNavigationKeywords(step.held);
          await driver.swipe(step.keyword === '$seen' ? left : right, y,
            step.keyword === '$seen' ? right : left, y, 600);
          await driver.delayMs(300);
          const row: Rect = await (await required(driver, 'remote-mail-mail-00')).getBounds();
          const action = await required(driver, `swipe-${step.keyword === '$seen' ? 'read' : 'star'}-mail-00`);
          const button: Rect = await action.getBounds();
          const actionEnabled = await action.isEnabled();
          expect(row.bottom - row.top >= 44 * density && row.bottom - row.top <= 135 * density).assertTrue();
          expect(Math.abs(button.top - row.top) <= 2 && Math.abs(button.bottom - row.bottom) <= 2).assertTrue();
          expect(button.left >= row.left - 2 && button.right <= row.right + 2).assertTrue();
          expect(button.right - button.left >= 44 * density).assertTrue();
          const inset = 6 * density;
          const tapX = Math.round(step.point === 'upper-left' ? button.left + inset :
            step.point === 'lower-right' ? button.right - inset : (button.left + button.right) / 2);
          const tapY = Math.round(step.point === 'upper-left' ? button.top + inset :
            step.point === 'lower-right' ? button.bottom - inset : (button.top + button.bottom) / 2);
          await delegator.print(`SWIPE_ACTION_BOUNDS: ${JSON.stringify({ index: index, point: step.point, density: density, row: row, button: button, x: tapX, y: tapY, actionEnabled: actionEnabled })}\n`);
          if (index === 0) { await capture('read-open'); }
          if (index === 1) { await capture('unread-open'); }
          if (index === 2) { await capture('star-open'); }
          expect(actionEnabled).assertTrue();
          expected.push(`Beta:setKeyword:${step.keyword}:${step.enabled}`);
          if (step.held) { await driver.doubleClick(tapX, tapY); }
          else { await driver.click(tapX, tapY); }
          for (let attempt = 0; attempt < 30 && ability.navigationCallCount() < expected.length; attempt++) { await driver.delayMs(100); }
          expect(ability.navigationCallSummary()).assertEqual(expected.join(','));
          await inboxOnly(driver);
          if (step.held) {
            expect(ability.navigationPendingKeywords()).assertEqual(1);
            await driver.delayMs(200);
            expect(ability.navigationCallSummary()).assertEqual(expected.join(','));
            await capture('held'); ability.holdNavigationKeywords(false);
          }
          for (let attempt = 0; attempt < 30; attempt++) {
            const cached = await store.mail.email(account.id, mail.id, true);
            if (cached?.mail.keywords.includes(step.keyword) === step.enabled && cached.stateDirty === false) { break; }
            await driver.delayMs(100);
          }
          const cached = await store.mail.email(account.id, mail.id, true);
          expect(cached?.mail.keywords.includes(step.keyword)).assertEqual(step.enabled);
          expect(cached?.stateDirty).assertFalse(); expect(cached?.mail.textBody).assertEqual(mail.textBody);
          // Completed acknowledgements re-enable the next native swipe action.
          await driver.delayMs(250); await inboxOnly(driver);
          expect(ability.navigationCallSummary()).assertEqual(expected.join(','));
          expect(ability.navigationViolationCount()).assertEqual(0);
          await delegator.print(`SWIPE_ACTION_STEP: ${JSON.stringify({ index: index, keyword: step.keyword, enabled: step.enabled, held: step.held, point: step.point, calls: ability.navigationCallSummary(), pending: ability.navigationPendingKeywords(), violations: ability.navigationViolationCount() })}\n`);
        }
        await capture('final');
      } finally {
        await delegator.print('SWIPE_ACTION_STAGE: cleanup isolated fixture\n');
        ability.holdNavigationKeywords(false);
        try { await ability.hideNavigationFixture(); await driver.delayMs(200); }
        catch (_) { await delegator.print('SWIPE_ACTION_STAGE: cleanup window already unavailable\n'); }
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); application.setColorMode(previousMode);
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
