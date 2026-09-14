// One bounded synthetic conversation and pending-operation flow, without sockets.
import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON, Component, On } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapEmail, JmapMailbox } from '../../../main/ets/mail/jmap/JmapClient';
import { NavigationFixtureState, navigationAccount, navigationMailbox, navigationMail } from '../support/NavigationClient';
import { NavigationTestSession } from '../support/NavigationTestSession';

async function required(driver: Driver, selector: On): Promise<Component> {
  const value = await driver.waitForComponent(selector, 5000);
  expect(value !== null).assertTrue(); return value;
}
async function readerVisible(driver: Driver, selector: On, towardTop: boolean = false): Promise<Component> {
  for (let attempt = 0; attempt < 7; attempt++) {
    const pane = await (await required(driver, ON.id('reader-scroll'))).getBounds();
    const value = await driver.findComponent(selector.within(ON.id('reader-scroll')));
    if (value !== null) {
      const bounds = await value.getBounds();
      if (bounds.top >= pane.top && bounds.bottom <= pane.bottom && bounds.bottom > bounds.top) { return value; }
    }
    const x = Math.round((pane.left + pane.right) / 2), height = pane.bottom - pane.top;
    await driver.swipe(x, Math.round(pane.top + height * (towardTop ? 0.25 : 0.80)),
      x, Math.round(pane.top + height * (towardTop ? 0.80 : 0.35)), 450);
    await driver.delayMs(250);
  }
  throw new Error('Conversation control was not visible');
}
function sentMailbox(): JmapMailbox {
  const box = navigationMailbox(); box.id = 'sent'; box.name = 'Sent'; box.role = 'sent'; box.totalEmails = 2;
  return box;
}
function sentReply(): JmapEmail {
  const mail = navigationMail('Beta', 0, 0, true);
  mail.id = 'sent-01'; mail.threadId = mail.id; mail.mailboxIds = ['sent'];
  mail.messageIds = ['sent-reply@example.test']; mail.inReplyTo = ['Beta-00@example.test'];
  mail.references = ['Beta-00@example.test']; mail.receivedAt += 60000;
  mail.subject = 'Beta sent reply'; mail.preview = 'Beta Sent reply';
  mail.from = [{ name: 'Beta owner', email: 'beta@example.test' }];
  mail.htmlBody = '<p>Beta Sent reply</p><blockquote><p>Earlier quoted paragraph.</p><blockquote><p>Nested quoted paragraph.</p></blockquote></blockquote>';
  mail.textBody = 'Beta Sent reply\n\n> Earlier quoted paragraph.\n>> Nested quoted paragraph.';
  mail.hasHtmlBody = true; return mail;
}

export default function conversationNavigationTests(): void {
  describe('CachedConversationNavigation', () => {
    it('cached_sent_thread_quotes_and_pending_flags_survive_account_switch', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const ability = await NavigationTestSession.acquire();
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      const capture = async (name: string): Promise<void> => {
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/navigation-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        NavigationFixtureState.reset();
        for (const account of await store.list()) { await store.remove(account.id); }
        const alpha = await store.add('https://alpha.example.test/session', navigationAccount('Alpha'), 'alpha-synthetic-token', 'alpha@example.test');
        const beta = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'beta-synthetic-token', 'beta@example.test');
        const alphaMail = navigationMail('Alpha', 0, 0, true), root = navigationMail('Beta', 0, 0, true);
        const received = navigationMail('Beta', 1, 0, true);
        received.inReplyTo = ['sent-reply@example.test']; received.references = ['Beta-00@example.test', 'sent-reply@example.test'];
        received.receivedAt = root.receivedAt + 120000;
        const unrelated = navigationMail('Beta', 2, 0, true); unrelated.subject = root.subject;
        const sent = sentReply(); const duplicate = sentReply(); duplicate.id = 'sent-copy'; duplicate.threadId = duplicate.id;
        await store.mail.saveBoxes(alpha.id, [navigationMailbox()], false);
        await store.mail.saveView(alpha.id, 'inbox', [alphaMail]); await store.mail.saveEmail(alpha.id, alphaMail);
        await store.mail.saveBoxes(beta.id, [navigationMailbox(), sentMailbox()], false);
        await store.mail.saveView(beta.id, 'inbox', [root, received, unrelated]);
        await store.mail.saveView(beta.id, 'sent', [sent, duplicate]);
        for (const mail of [root, received, unrelated, sent, duplicate]) { await store.mail.saveEmail(beta.id, mail); }
        await store.rememberVisitedAccount(beta.id); NavigationFixtureState.betaOffline = true;
        await AppLanguage.set(ability.context, 'en'); await ability.showNavigationFixture();
        expect(await (await required(driver, ON.id('inbox-account-label'))).getText()).assertEqual('beta@example.test');
        expect(await (await required(driver, ON.id('conversation-count-mail-00'))).getText()).assertEqual('3');
        await required(driver, ON.id('remote-mail-mail-00')); await required(driver, ON.id('remote-mail-mail-02'));
        expect(await driver.findComponent(ON.id('remote-mail-mail-01')) === null).assertTrue();
        expect(NavigationFixtureState.calls.length).assertEqual(0); await capture('thread-inbox');
        await (await required(driver, ON.id('remote-mail-mail-00'))).click();
        expect(await (await required(driver, ON.id('reader-subject'))).getText()).assertEqual(root.subject);
        await readerVisible(driver, ON.text('Beta cached body'));
        expect((await driver.findComponents(ON.id('expanded-message'))).length).assertEqual(1);
        expect(NavigationFixtureState.calls.length).assertEqual(0); await capture('thread-reader');
        await (await readerVisible(driver, ON.id('conversation-message-sent-01'), true)).click();
        expect(await (await required(driver, ON.id('reader-subject'))).getText()).assertEqual(sent.subject);
        await readerVisible(driver, ON.text('Beta Sent reply'));
        const showQuote = await readerVisible(driver, ON.text('Show quoted text'));
        expect(await driver.findComponent(ON.text('Earlier quoted paragraph.').within(ON.id('reader-scroll'))) === null).assertTrue();
        await showQuote.click(); await driver.delayMs(250);
        await readerVisible(driver, ON.text('Earlier quoted paragraph.'));
        await readerVisible(driver, ON.text('Nested quoted paragraph.'));
        expect((await driver.findComponents(ON.id('expanded-message'))).length).assertEqual(1);
        expect(NavigationFixtureState.calls.length).assertEqual(0); await capture('thread-quote');
        await (await readerVisible(driver, ON.text('Hide quoted text'), true)).click(); await driver.delayMs(250);
        expect(await driver.findComponent(ON.text('Earlier quoted paragraph.').within(ON.id('reader-scroll'))) === null).assertTrue();
        await driver.pressBack(); await required(driver, ON.id('remote-mail-mail-00'));

        NavigationFixtureState.betaOffline = false; NavigationFixtureState.holdKeywords = true;
        const before = (await store.mail.email(beta.id, 'mail-00'))!;
        const row = await (await required(driver, ON.id('remote-mail-mail-00'))).getBounds();
        const y = Math.round((row.top + row.bottom) / 2);
        await driver.swipe(Math.round(row.left + (row.right - row.left) * 0.85), y,
          Math.round(row.left + (row.right - row.left) * 0.25), y, 600);
        await (await required(driver, ON.id('swipe-star-mail-00').enabled(true))).click();
        await required(driver, ON.id('remote-star-mail-00'));
        for (let attempt = 0; attempt < 30 && NavigationFixtureState.pendingKeywords === 0; attempt++) { await driver.delayMs(100); }
        expect(NavigationFixtureState.pendingKeywords).assertEqual(1);
        const pending = (await store.mail.email(beta.id, 'mail-00', true))!;
        expect(pending.stateDirty).assertTrue(); expect(pending.mail.keywords.includes('$flagged')).assertFalse();
        // Network acknowledgement is still pending while the account menu works.
        await (await required(driver, ON.id('inbox-account').enabled(true))).click();
        await (await required(driver, ON.id(`switch-account-${alpha.id}`).enabled(true))).click();
        expect(await (await required(driver, ON.id('inbox-account-label'))).getText()).assertEqual('alpha@example.test');
        await required(driver, ON.text('Alpha cached message 00').within(ON.id('mail-list')));
        expect(NavigationFixtureState.pendingKeywords).assertEqual(1);
        NavigationFixtureState.completeKeywords();
        for (let attempt = 0; attempt < 30; attempt++) {
          const saved = await store.mail.email(beta.id, 'mail-00', true);
          if (saved && saved.stateDirty === false && saved.mail.keywords.includes('$flagged')) { break; }
          await driver.delayMs(100);
        }
        const confirmed = (await store.mail.email(beta.id, 'mail-00'))!;
        expect(confirmed.mail.keywords.includes('$flagged')).assertTrue(); expect(confirmed.stateDirty).assertFalse();
        expect(confirmed.mail.textBody).assertEqual(before.mail.textBody);
        expect(confirmed.savedAt).assertEqual(before.savedAt); expect(confirmed.bodySavedAt).assertEqual(before.bodySavedAt);
        expect(confirmed.bodyDecoderRevision).assertEqual(before.bodyDecoderRevision);
        expect((await store.mail.email(alpha.id, 'mail-00'))?.mail.keywords.includes('$flagged')).assertFalse();
        expect(await driver.findComponent(ON.id('remote-star-mail-00')) === null).assertTrue();
        expect(await (await required(driver, ON.id('inbox-account-label'))).getText()).assertEqual('alpha@example.test');
        expect((await store.lastVisitedAccount())?.id).assertEqual(alpha.id);
        expect(NavigationFixtureState.calls.join(',')).assertEqual('Beta:setKeyword:$flagged:true');
        expect(NavigationFixtureState.violations.length).assertEqual(0); await capture('async-switch');
      } finally {
        NavigationFixtureState.completeKeywords(); NavigationFixtureState.holdKeywords = false;
        await driver.delayMs(200); await ability.hideNavigationFixture(); await driver.delayMs(200);
        await store.open(ability.context);
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close(); await NavigationTestSession.release();
      }
    });
  });
}
