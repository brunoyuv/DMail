// Three genuine UI captures with fictional cached mail. Never send or connect.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { conversationMessages } from '../../../main/ets/mail/Conversation';
import { OutgoingDraft } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 5000);
  if (value === null) {
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/store-failure.png');
    await delegator.executeShellCommand('uitest dumpLayout -p /data/local/tmp/store-failure.json');
    throw new Error(`Missing screenshot component: ${id}`);
  }
  return value;
}
export default function tests(): void {
  describe('StoreScreenshots', () => {
    it('capture_inbox_html_reader_and_saved_composer_without_network', 0, async () => {
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
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        await driver.delayMs(1400); // Settle native navigation and ArkWeb layout.
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/store-${name}.png`)).exitCode).assertEqual(0);
        await delegator.print(`STORE_SCREENSHOT: ${name} ${screen.width}x${screen.height}\n`);
      };
      try {
        ability.resetNavigationFixtureState();
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://alpha.example.test/session', navigationAccount('Alpha'),
          'screenshot-synthetic-token', 'alex.morgan@example.test');
        const senders = ['Field Notes', 'Maya Chen', 'River Studio', 'Noah Williams', 'The Local Library', 'Sam Taylor', 'Sunday Table'];
        const subjects = ['A little room to grow', 'Saturday by the coast', 'Your workshop details', 'Re: Our autumn reading list',
          'Your reservation is ready', 'A few photos from the weekend', 'Something delicious for Sunday'];
        const previews = ['Small ideas for a slower weekend. A windowsill, a quiet morning, and a little room to grow.',
          'Shall we catch the nine o\'clock train? I know a lovely little place for coffee by the water.',
          'We look forward to seeing you on Thursday. Everything you need for the pottery workshop is here.',
          'I added two more books to the list. The first one is perfect for a rainy afternoon.',
          'Good news! The book you reserved is waiting for you at the front desk.',
          'The light was beautiful on our walk. Here are a few favourites from the trip.',
          'A simple seasonal recipe to bring everyone around the table.'];
        const messages: JmapEmail[] = [];
        for (let index = 0; index < senders.length; index++) {
          const mail = navigationMail('Alpha', index, 0, true);
          mail.from = [{ name: senders[index], email: `hello${index}@example.test` }];
          mail.to = [{ name: 'Alex Morgan', email: 'alex.morgan@example.test' }];
          mail.subject = subjects[index]; mail.preview = previews[index];
          mail.receivedAt = Date.now() - index * 3600000;
          mail.keywords = index === 1 || index === 3 ? [] : index === 2 ? ['$seen', '$flagged'] : ['$seen'];
          mail.textBody = previews[index]; messages.push(mail);
        }
        const html = await ability.context.resourceManager.getRawFileContent('store-newsletter.html');
        messages[0].htmlBody = util.TextDecoder.create('utf-8').decodeToString(html);
        messages[0].hasHtmlBody = true;
        const workshop = await ability.context.resourceManager.getRawFileContent('store-workshop.html');
        messages[2].htmlBody = util.TextDecoder.create('utf-8').decodeToString(workshop);
        messages[2].hasHtmlBody = true;
        // Link received and Sent copies by real reply headers, not the subject
        // or a shared artificial thread ID. Every message has a distinct ID.
        const invitation = messages[2]; invitation.threadId = invitation.id;
        const sent = navigationMail('Alpha', 8, 0, true);
        sent.id = 'workshop-sent'; sent.threadId = sent.id; sent.mailboxIds = ['sent'];
        sent.messageIds = ['workshop-sent@example.test']; sent.inReplyTo = invitation.messageIds;
        sent.references = invitation.messageIds;
        sent.from = [{ name: 'Alex Morgan', email: 'alex.morgan@example.test' }];
        sent.to = [{ name: 'River Studio', email: 'hello2@example.test' }];
        sent.subject = 'Re: Your workshop details'; sent.receivedAt = Date.now() - 75 * 60000;
        sent.textBody = 'Thanks for the lovely invitation. Could I bring my own sketchbook?';
        sent.preview = sent.textBody;
        const confirmation = navigationMail('Alpha', 9, 0, true);
        confirmation.id = 'workshop-confirmation'; confirmation.threadId = confirmation.id;
        confirmation.messageIds = ['workshop-confirmation@example.test'];
        confirmation.inReplyTo = sent.messageIds;
        confirmation.references = invitation.messageIds.concat(sent.messageIds);
        confirmation.from = [{ name: 'Lena at River Studio', email: 'hello2@example.test' }];
        confirmation.to = invitation.to; confirmation.subject = sent.subject;
        confirmation.receivedAt = Date.now() - 30 * 60000;
        confirmation.preview = 'Absolutely — bring your sketchbook! We\'ll have clay and a cup of tea ready.';
        confirmation.textBody = confirmation.preview;
        confirmation.htmlBody = util.TextDecoder.create('utf-8').decodeToString(
          await ability.context.resourceManager.getRawFileContent('store-workshop-reply.html'));
        confirmation.hasHtmlBody = true;
        messages.splice(1, 0, confirmation);
        const sentBox = navigationMailbox(); sentBox.id = 'sent'; sentBox.name = 'Sent'; sentBox.role = 'sent';
        sentBox.totalEmails = 1; sentBox.unreadEmails = 0;
        const box = navigationMailbox(); box.totalEmails = messages.length; box.unreadEmails = 2;
        await store.mail.saveBoxes(account.id, [box, sentBox], false);
        await store.mail.saveView(account.id, 'inbox', messages);
        await store.mail.saveView(account.id, 'sent', [sent]); await store.mail.saveEmail(account.id, sent);
        for (const mail of messages) { await store.mail.saveEmail(account.id, mail); }
        const cached = await store.mail.cachedMessages(account.id);
        expect(conversationMessages(confirmation, cached.map(value => value.mail)).length).assertEqual(3);
        await store.rememberVisitedAccount(account.id);
        const draft = new OutgoingDraft(); draft.id = 'store-screenshot-draft'; draft.date = Date.now();
        draft.to = 'maya@example.test'; draft.subject = 'Saturday by the coast';
        draft.senderName = 'Alex Morgan'; draft.compositionApplied = true;
        draft.text = 'Hi Maya,\n\nSaturday sounds lovely. Let\'s catch the nine o\'clock train and take the scenic route along the coast.\n\nI\'ll bring coffee for the journey. Shall we stop at that little bookshop on the way back?\n\nLooking forward to it!\n\nAlex';
        await store.saveOutgoing(account.id, draft);
        await AppLanguage.set(ability.context, 'en'); application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await ability.showStoreScreenshotFixture();
        await required(driver, 'remote-mail-mail-00'); await required(driver, 'unread-marker-mail-01');
        expect(await (await required(driver, 'conversation-count-workshop-confirmation')).getText()).assertEqual('3');
        expect(await driver.findComponent(ON.id('remote-mail-mail-02')) === null).assertTrue();
        if (screen.width > screen.height) {
          await (await required(driver, 'remote-mail-mail-00')).click();
          expect(await driver.waitForComponent(ON.id('reader-subject').text(subjects[0]), 5000) !== null).assertTrue();
          await required(driver, 'html-mail');
        }
        await capture('inbox');
        await (await required(driver, 'remote-mail-workshop-confirmation')).click();
        expect(await driver.waitForComponent(ON.id('reader-subject').text(confirmation.subject), 5000) !== null).assertTrue();
        await required(driver, 'html-mail'); await driver.delayMs(800);
        await required(driver, 'conversation-message-mail-02');
        const sentCard = await required(driver, 'conversation-message-workshop-sent');
        expect((await driver.findComponents(ON.id('expanded-message'))).length).assertEqual(1);
        // Demonstrate an earlier sent reply can expand, then fold it again by
        // returning to the latest received message in this same conversation.
        await sentCard.click(); await driver.delayMs(500);
        await required(driver, 'conversation-message-workshop-confirmation');
        expect(await driver.findComponent(ON.id('conversation-message-workshop-sent')) === null).assertTrue();
        await (await required(driver, 'conversation-message-workshop-confirmation')).click();
        await required(driver, 'conversation-message-workshop-sent'); await driver.delayMs(600);
        const showQuote = await driver.waitForComponent(ON.text('Show quoted text'), 5000);
        expect(showQuote !== null).assertTrue();
        expect(await driver.findComponent(ON.text('Could I bring my own sketchbook?')) === null).assertTrue();
        await showQuote.click();
        expect(await driver.waitForComponent(ON.text('Could I bring my own sketchbook?'), 5000) !== null).assertTrue();
        const hideQuote = await driver.waitForComponent(ON.text('Hide quoted text'), 5000);
        expect(hideQuote !== null).assertTrue(); await hideQuote.click(); await driver.delayMs(500);
        expect(await driver.findComponent(ON.text('Could I bring my own sketchbook?')) === null).assertTrue();
        expect((await driver.findComponents(ON.id('expanded-message'))).length).assertEqual(1);
        await capture('reader');
        await delegator.print('STORE_CONVERSATION_RESULT: three header-linked Inbox/Sent messages; earlier sent reply expanded and collapsed; quoted text expanded and folded\n');
        // Re-enter the same cache-backed inbox to work on both compact and split layouts.
        await ability.hideNavigationFixture(); await driver.delayMs(250);
        await ability.showStoreScreenshotFixture(); await required(driver, 'compose-mail');
        await (await required(driver, 'compose-mail')).click();
        await required(driver, 'compose-panel');
        expect(await (await required(driver, 'compose-subject')).getText()).assertEqual(draft.subject);
        await capture('composer');
        expect(ability.navigationCallCount()).assertEqual(0);
        expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('STORE_SCREENSHOTS_RESULT: three captures; zero mail calls, no send\n');
      } finally {
        await ability.hideNavigationFixture(); await driver.delayMs(200);
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close(); application.setColorMode(previousMode);
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
