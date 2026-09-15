// Focused shipping UI layout check with cached synthetic mail and no sockets.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component, Rect } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { OutgoingDraft } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 5000);
  expect(value !== null).assertTrue(); return value;
}
function centerY(rect: Rect): number { return (rect.top + rect.bottom) / 2; }
function target44(rect: Rect, density: number): void {
  expect(rect.right - rect.left >= 44 * density - 2).assertTrue();
  expect(rect.bottom - rect.top >= 44 * density - 2).assertTrue();
}
export default function tests(): void {
  describe('PreviewLayout', () => {
    it('tablet_preview_title_split_reader_and_composer_match_both_orientations', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      await ability.hideNavigationFixture();
      const mainWindow = await window.getLastWindow(ability.context);
      const previousOrientation = mainWindow.getPreferredOrientation();
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        expect(await driver.findComponent(ON.id('navigation-fixture-marker')) !== null).assertTrue();
        const screen = display.getDefaultDisplaySync();
        await delegator.print(`PREVIEW_LAYOUT_SCREEN: ${JSON.stringify({ name: name, width: screen.width, height: screen.height, density: screen.densityPixels })}\n`);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/preview-layout-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        ability.resetNavigationFixtureState();
        for (const account of await store.list()) { await store.remove(account.id); }
        const account = await store.add('https://alpha.example.test/session', navigationAccount('Alpha'), 'preview-synthetic-token', 'alex.morgan@example.test');
        const messages: JmapEmail[] = [];
        const senders = ['Field Notes', 'Maya Chen', 'River Studio', 'Noah Williams', 'The Local Library', 'Sam Taylor'];
        const subjects = ['A little room to grow', 'Saturday by the coast', 'Your workshop details', 'Re: Reading list', 'Your reservation is ready', 'A few photos from the weekend'];
        for (let index = 0; index < senders.length; index++) {
          const mail = navigationMail('Alpha', index, 0, true);
          mail.from = [{ name: senders[index], email: `sender${index}@example.test` }];
          mail.to = [{ name: 'Alex Morgan', email: 'alex.morgan@example.test' }];
          mail.subject = subjects[index];
          mail.preview = index === 0 ? 'Small ideas for a slower weekend. A synthetic newsletter for layout testing.' : 'A short synthetic message for the inbox layout preview.';
          mail.keywords = index === 1 ? [] : index === 2 ? ['$seen', '$flagged'] : ['$seen'];
          messages.push(mail);
        }
        messages[0].htmlBody = '<section style="background:#f7f5eb;color:#293b30"><header style="background:#294f43;color:white;padding:24px"><p>FIELD NOTES · SYNTHETIC PREVIEW</p><h1 style="font-size:36px;margin:10px 0">A little room<br>to grow.</h1></header><div style="padding:24px"><h2>Good things take a little time.</h2><p>A windowsill, a balcony, a quiet corner of the garden. You do not need much space to start something new.</p><p>This synthetic newsletter checks the original HTML inside the native reader.</p><p>Until next time,<br>The Field Notes team</p></div></section>';
        messages[0].hasHtmlBody = true;
        await store.mail.saveBoxes(account.id, [navigationMailbox()], false);
        await store.mail.saveView(account.id, 'inbox', messages);
        await store.mail.saveEmail(account.id, messages[0]);
        await store.rememberVisitedAccount(account.id);
        const draft = new OutgoingDraft(); draft.id = 'synthetic-preview-draft'; draft.date = Date.now();
        draft.to = 'maya@example.test'; draft.subject = 'Saturday by the coast';
        draft.text = 'Hi Maya,\n\nNine works perfectly. I will bring some coffee for the journey.\n\nSee you at the station!\n\nAlex';
        await store.saveOutgoing(account.id, draft);
        await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);

        for (const orientation of [window.Orientation.LANDSCAPE, window.Orientation.PORTRAIT]) {
          const label = orientation === window.Orientation.LANDSCAPE ? 'landscape' : 'portrait';
          await mainWindow.setPreferredOrientation(orientation); await driver.delayMs(1000);
          await ability.showNavigationFixture();
          await required(driver, 'navigation-fixture-marker');
          await required(driver, 'remote-mail-mail-00'); await driver.delayMs(500);
          const density = display.getDefaultDisplaySync().densityPixels;
          const title = await (await required(driver, 'inbox-title')).getBounds();
          const compose = await (await required(driver, 'compose-mail')).getBounds();
          const boxes = await (await required(driver, 'open-mailboxes')).getBounds();
          target44(compose, density); target44(boxes, density);
          expect(Math.abs(centerY(title) - centerY(compose)) <= 3 * density).assertTrue();
          expect(Math.abs(centerY(compose) - centerY(boxes)) <= density).assertTrue();
          expect(title.right <= compose.left + 2 && compose.right < boxes.left).assertTrue();
          expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
          // The unread marker must not determine the row's intrinsic height.
          const firstRow = await (await required(driver, 'remote-mail-mail-00')).getBounds();
          const unreadRow = await (await required(driver, 'remote-mail-mail-01')).getBounds();
          expect(unreadRow.bottom - unreadRow.top <= 135 * density).assertTrue();
          expect(unreadRow.top >= firstRow.bottom - 2 && unreadRow.top <= firstRow.bottom + 2).assertTrue();
          const marker = await (await required(driver, 'unread-marker-mail-01')).getBounds();
          expect(Math.abs(marker.left - unreadRow.left) <= 2).assertTrue();
          expect(marker.right - marker.left >= 3 * density - 1 && marker.right - marker.left <= 3 * density + 1).assertTrue();
          expect(marker.bottom - marker.top >= 30 * density && marker.bottom - marker.top < unreadRow.bottom - unreadRow.top).assertTrue();
          expect(marker.top >= unreadRow.top && marker.bottom <= unreadRow.bottom).assertTrue();
          await delegator.print(`PREVIEW_LAYOUT_ROWS: ${JSON.stringify({ orientation: label, density: density, first: firstRow, unread: unreadRow, marker: marker })}\n`);
          await delegator.print(`PREVIEW_LAYOUT_TITLE: ${JSON.stringify({ orientation: label, density: density, title: title, compose: compose, mailboxes: boxes })}\n`);
          await capture(`${label}-inbox`);

          await (await required(driver, 'remote-mail-mail-00')).click();
          await required(driver, 'reader-subject'); await required(driver, 'html-mail'); await driver.delayMs(900);
          const inbox = await (await required(driver, 'mail-list')).getBounds();
          const reader = await (await required(driver, 'reader-scroll')).getBounds();
          expect(inbox.right <= reader.left + 2).assertTrue();
          expect(inbox.bottom > reader.top && reader.bottom > inbox.top).assertTrue();
          expect(reader.right - reader.left >= 350 * density).assertTrue();
          await delegator.print(`PREVIEW_LAYOUT_SPLIT: ${JSON.stringify({ orientation: label, density: density, inbox: inbox, reader: reader })}\n`);
          await capture(`${label}-reader`);

          await (await required(driver, 'compose-mail')).click();
          await required(driver, 'compose-panel'); await required(driver, 'compose-body'); await driver.delayMs(500);
          expect(await (await required(driver, 'compose-subject')).getText()).assertEqual(draft.subject);
          const cancel = await (await required(driver, 'cancel-compose')).getBounds();
          const send = await (await required(driver, 'send-mail')).getBounds();
          target44(cancel, density); target44(send, density);
          expect(Math.abs(centerY(cancel) - centerY(send)) <= density).assertTrue();
          await capture(`${label}-composer`);
          await ability.hideNavigationFixture(); await driver.delayMs(200);
        }
        expect(ability.navigationCallCount()).assertEqual(0);
        expect(ability.navigationViolationCount()).assertEqual(0);
      } finally {
        await ability.hideNavigationFixture(); await driver.delayMs(200);
        await store.open(ability.context);
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
        application.setColorMode(previousMode);
        await mainWindow.setPreferredOrientation(previousOrientation);
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
