// Cached synthetic metadata only: this test never invokes a picker, viewer or Send.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { OutgoingDraft } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { OutgoingAttachment, outgoingAttachmentReference } from '../../../main/ets/mail/attachments/OutgoingAttachmentModel';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 3000);
  if (value === null) {
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    await delegator.print(`ATTACHMENTS_MISSING: ${id}\n`);
    await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/attachments-failure.png');
  }
  expect(value !== null).assertTrue(); return value;
}
async function enabled(driver: Driver, id: string): Promise<Component> {
  const value = await required(driver, id);
  for (let attempt = 0; attempt < 30 && !await value.isEnabled(); attempt++) { await driver.delayMs(50); }
  expect(await value.isEnabled()).assertTrue(); return value;
}
function outgoing(accountId: string, draftId: string, id: string, name: string, size: number): OutgoingAttachment {
  return { id, name, size, contentType: 'application/pdf', file: outgoingAttachmentReference(accountId, draftId, id) };
}

export default function tests(): void {
  describe('ComposeAttachments', () => {
    it('cached_received_card_and_unicode_draft_removal_survive_reopen', 0, async () => {
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
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        await required(driver, 'navigation-fixture-marker'); await driver.delayMs(300);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/attachments-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'attachments-synthetic-token', 'beta@example.test');
        const inbox = navigationMailbox(); inbox.totalEmails = 1;
        const mail = navigationMail('Beta', 1, 0, true);
        mail.from = [{ name: 'Synthetic sender', email: 'sender@example.test' }];
        mail.subject = 'Synthetic PDF attachment'; mail.textBody = 'Synthetic attachment preview only.';
        mail.hasAttachment = true;
        mail.attachments = [{ id: '2', name: '物理学报告 café.pdf', contentType: 'application/pdf', size: 4096, sizeIsEncoded: false }];
        await store.mail.saveBoxes(account.id, [inbox], false);
        await store.mail.saveView(account.id, 'inbox', [mail]); await store.mail.saveEmail(account.id, mail);
        const initialBody = await store.mail.email(account.id, mail.id, true);
        await delegator.print(`ATTACHMENTS_CACHE: seed=${initialBody !== null}, text=${typeof initialBody?.mail.textBody === 'string'}, attachments=${initialBody?.mail.attachments?.length ?? -1}\n`);
        expect(initialBody?.mail.textBody).assertEqual(mail.textBody);

        const draft = new OutgoingDraft(); draft.id = '10000000-0000-0000-0000-000000000001'; draft.date = Date.now();
        draft.to = 'recipient@example.test'; draft.subject = 'Synthetic attachment draft'; draft.text = 'Synthetic draft only.';
        draft.compositionApplied = true;
        const first = outgoing(account.id, draft.id, '20000000-0000-0000-0000-000000000001', '附件一 résumé.pdf', 2048);
        const second = outgoing(account.id, draft.id, '20000000-0000-0000-0000-000000000002', '附件二 東京.pdf', 3072);
        draft.attachments = [first, second]; await store.saveOutgoing(account.id, draft);
        await store.rememberVisitedAccount(account.id); await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        ability.setNavigationInboxForeground(true);
        await ability.showNavigationFixture(); await required(driver, 'navigation-fixture-marker');

        if (screen.width / density >= 760) {
          await (await required(driver, 'inbox-account')).click();
          const menu = await required(driver, 'account-picker');
          const bounds = await menu.getBounds();
          expect((bounds.right - bounds.left) / density <= 340).assertTrue();
          await capture('account-menu');
          await (await required(driver, `switch-account-${account.id}`)).click();
          await driver.delayMs(400);
          await delegator.print('ATTACHMENTS_STAGE: tablet account menu is bounded to 320vp\n');
        }

        const reopenedBody = await store.mail.email(account.id, mail.id, true);
        await delegator.print(`ATTACHMENTS_CACHE: afterUI=${reopenedBody !== null}, text=${typeof reopenedBody?.mail.textBody === 'string'}, attachments=${reopenedBody?.mail.attachments?.length ?? -1}\n`);
        expect(reopenedBody?.mail.textBody).assertEqual(mail.textBody);
        await delegator.print('ATTACHMENTS_STAGE: opening cached received attachment\n');
        await (await required(driver, 'remote-mail-mail-01')).click();
        await enabled(driver, 'attachment-2'); await enabled(driver, 'save-attachment-2');
        expect(await driver.findComponent(ON.text(mail.attachments[0].name).within(ON.id('attachment-2'))) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('PDF · 4 KB').within(ON.id('attachment-2'))) !== null).assertTrue();
        if (screen.width / density >= 760) {
          const list = await (await required(driver, 'mail-list')).getBounds();
          const reader = await (await required(driver, 'reader-scroll')).getBounds();
          expect(list.right <= reader.left + 2).assertTrue(); expect(reader.right - reader.left >= 350 * density).assertTrue();
          await delegator.print('ATTACHMENTS_STAGE: tablet split reader preserved\n');
        }
        await capture('received');
        await (await required(driver, 'reader-back')).click();
        await (await required(driver, 'compose-mail')).click();
        await enabled(driver, `remove-compose-attachment-${first.id}`);
        await required(driver, `compose-attachment-${second.id}`);
        expect(await driver.findComponent(ON.text(first.name).within(ON.id(`compose-attachment-${first.id}`))) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('2 KB').within(ON.id(`compose-attachment-${first.id}`))) !== null).assertTrue();
        expect(await driver.findComponent(ON.text(second.name).within(ON.id(`compose-attachment-${second.id}`))) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('3 KB').within(ON.id(`compose-attachment-${second.id}`))) !== null).assertTrue();
        await capture('composer-before');
        await (await enabled(driver, `remove-compose-attachment-${first.id}`)).click();
        for (let attempt = 0; attempt < 30; attempt++) {
          if ((await store.outgoing(account.id))?.attachments.length === 1) { break; }
          await driver.delayMs(50);
        }
        const removed = await store.outgoing(account.id);
        expect(removed !== null).assertTrue(); expect(removed!.attachments.length).assertEqual(1);
        expect(removed!.attachments[0].id).assertEqual(second.id);
        expect(await driver.findComponent(ON.id(`compose-attachment-${first.id}`)) === null).assertTrue();
        await capture('composer-after');
        await (await required(driver, 'cancel-compose')).click();
        const keep = await driver.waitForComponent(ON.text('Save draft'), 3000); expect(keep !== null).assertTrue(); await keep.click();
        await driver.delayMs(550);
        await (await required(driver, 'compose-mail')).click();
        await enabled(driver, `remove-compose-attachment-${second.id}`);
        expect(await driver.findComponent(ON.id(`compose-attachment-${first.id}`)) === null).assertTrue();
        expect(await driver.findComponent(ON.text(second.name).within(ON.id(`compose-attachment-${second.id}`))) !== null).assertTrue();
        await capture('composer-reopened');
        expect(ability.navigationCallCount()).assertEqual(0); expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('ATTACHMENTS_RESULT: received PDF card and save control; Unicode draft filenames and sizes; removal persisted across reopen; zero mail service calls, picker, viewer or send\n');
      } finally {
        ability.setNavigationInboxForeground(false);
        try { await ability.hideNavigationFixture(); await driver.delayMs(200); } catch (_) {}
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); application.setColorMode(previousMode); ability.resetNavigationFixtureState();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
