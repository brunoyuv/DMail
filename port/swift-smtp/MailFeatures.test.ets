// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import deviceInfo from '@ohos.deviceInfo';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, MatchPattern } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { AccountStore, SavedAccount } from '../../../main/ets/data/AccountStore';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import { SmtpSettings, OutgoingDraft } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { BackgroundSend } from '../../../main/ets/mail/smtp/BackgroundSend';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
interface SmtpUiSession { mode: string; acceptancePending?: boolean; acceptanceHeld?: boolean; acceptanceReleased?: boolean; }
interface ImageStats { imageLoads: number; remoteLoads: number; sessions: SmtpUiSession[]; }
async function imageStats(): Promise<ImageStats> {
  const request = http.createHttp();
  try { return JSON.parse((await request.request('http://localhost:9770/stats')).result as string) as ImageStats; }
  finally { request.destroy(); }
}
async function smtpControl(path: string): Promise<void> {
  const request = http.createHttp();
  try {
    const response = await request.request(`http://localhost:9770${path}`, { method: http.RequestMethod.POST,
      connectTimeout: 2000, readTimeout: 2000 });
    expect(response.responseCode).assertEqual(200);
  } finally { request.destroy(); }
}

async function selectCachedInbox(driver: Driver, store: AccountStore, account: SavedAccount): Promise<void> {
  const inbox = (await store.mail.boxes(account.id))?.boxes.find(box => box.role === 'inbox');
  expect(inbox !== undefined).assertTrue();
  await (await driver.waitForComponent(ON.id(`remote-box-${inbox!.id}`).enabled(true), 5000)).click();
  expect(await driver.waitForComponent(ON.id('compose-mail').enabled(true), 5000) !== null).assertTrue();
}

async function sendWithoutBlocking(driver: Driver, store: AccountStore, account: SavedAccount, expectedCount: number): Promise<void> {
  await smtpControl('/ui/hold');
  try {
    await (await driver.waitForComponent(ON.id('send-mail').enabled(true), 5000)).click();
    expect(await driver.waitForComponent(ON.id('compose-mail').enabled(true), 5000) !== null).assertTrue();
    expect(await driver.findComponent(ON.id('compose-panel')) === null).assertTrue();
    let pending = false;
    for (let attempt = 0; attempt < 50; attempt++) {
      const sessions = (await imageStats()).sessions.filter(value => value.mode === 'ui');
      pending = sessions.length === expectedCount && sessions[expectedCount - 1].acceptancePending === true;
      if (pending) { break; }
      await driver.delayMs(100);
    }
    expect(pending).assertTrue();
    expect(BackgroundSend.isSending(account.id)).assertTrue();
    expect((await store.outgoing(account.id, true))?.state).assertEqual('sending');
    // Prove navigation works before SMTP acknowledges DATA, not merely after a
    // fast local fixture finishes. The same three submissions remain in order.
    await (await driver.waitForComponent(ON.id('open-mailboxes').enabled(true), 5000)).click();
    expect(await driver.waitForComponent(ON.id('open-settings').enabled(true), 5000) !== null).assertTrue();
    expect(BackgroundSend.isSending(account.id)).assertTrue();
    expect((await imageStats()).sessions.filter(value => value.mode === 'ui')[expectedCount - 1].acceptancePending).assertTrue();
    await selectCachedInbox(driver, store, account);
    await smtpControl('/ui/responsive');
    console.info(`MAIL_ASYNC_SEND: submission ${expectedCount} returned to inbox and opened mailboxes before SMTP acknowledgement`);
  } finally { await smtpControl('/ui/release'); }
  for (let attempt = 0; attempt < 100 && BackgroundSend.isSending(account.id); attempt++) { await driver.delayMs(100); }
  expect(BackgroundSend.isSending(account.id)).assertFalse();
  expect((await store.outgoing(account.id))?.state).assertEqual('sent');
  const sent = (await store.mail.cachedMessages(account.id)).filter(value => value.mail.id.startsWith('local_sent_'));
  expect(sent.length).assertEqual(expectedCount);
  expect(sent.every(value => value.bodySavedAt !== null && value.mail.messageIds.length === 1 &&
    (value.mail.textBody !== null || typeof value.mail.htmlBody === 'string') && !value.mail.bodyTruncated)).assertTrue();
  const boxes = await store.mail.boxes(account.id);
  expect(boxes?.boxes.some(box => box.role === 'sent')).assertTrue();
}
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('html:fixture-password'))}`;
  }
}
export default function tests(): void {
  describe('MailFeaturesOnTablet', () => {
    it('html_default_and_saved_composer_send', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      if (deviceInfo.abiList.includes('x86_64')) {
        const screen = display.getDefaultDisplaySync();
        await driver.swipe(Math.floor(screen.width / 2), Math.floor(screen.height * 0.8),
          Math.floor(screen.width / 2), Math.floor(screen.height * 0.2), 600);
        // Cold-boot unlock can precede DEVICE_UNLOCKED secure-store readiness.
        await driver.delayMs(5000);
      }
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      const store = new AccountStore('mail_features_test.db'); await store.open(ability.context);
      try {
        for (const account of await store.list()) { await store.remove(account.id); }
        const credentials = new Credentials();
        const client = new NativeImapClient('imaps://localhost:9761', credentials);
        const session = await client.connect();
        const account = await store.add('imaps://localhost:9761', session.accounts[0], (await credentials.authorization()).slice(6), 'sender@example.test');
        const settings = new SmtpSettings(); settings.endpoint = 'smtps://localhost:9771'; settings.username = 'ui'; settings.password = 'fixture-password';
        await store.saveSmtp(account, settings);
        const draft = new OutgoingDraft(); draft.id = util.generateRandomUUID(); draft.date = Date.now();
        draft.to = 'reader@example.test'; draft.subject = 'Tablet composer'; draft.text = 'Synthetic UI send 日本語';
        draft.state = 'sending'; await store.saveOutgoing(account.id, draft);
        expect((await store.outgoing(account.id))?.state).assertEqual('unconfirmed');
        draft.state = 'draft'; await store.saveOutgoing(account.id, draft);
        const page = await client.emailPage(account.serverId, (await client.mailboxes(account.serverId))[0].id);
        const mail = await client.readEmail(account.serverId, page.emails[0].id);
        expect(mail?.htmlBody?.includes('<strong>bold</strong>')).assertTrue();
        expect(mail?.textBody).assertEqual('Plain fallback 日本語');
        expect(mail?.htmlBody?.includes('data:image/png;base64,')).assertTrue();
        expect(mail?.bodyEncodingProblem).assertFalse();
        expect(mail?.cc?.[0].email).assertEqual('copy@example.test');
        expect(mail?.references?.join(',')).assertEqual('root@example.test,older@example.test');
        await AppLanguage.set(ability.context, 'en');
        console.info('MAIL_UI_STAGE: show fixture');
        await ability.showMailFeaturesFixture();
        await (await driver.waitForComponent(ON.id('open-mailboxes').enabled(true), 10000)).click();
        await (await driver.waitForComponent(ON.id('open-settings'), 5000)).click();
        await (await driver.waitForComponent(ON.id('language-zh-Hans'), 5000)).click();
        await driver.delayMs(700);
        expect(await driver.findComponent(ON.text('应用语言')) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('跟随系统')) !== null).assertTrue();
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-language-zh-tablet.png')).exitCode).assertEqual(0);
        await (await driver.findComponent(ON.id('language-default'))).click();
        await driver.delayMs(300); expect(AppLanguage.choice).assertEqual('default');
        await (await driver.findComponent(ON.id('language-en'))).click();
        await driver.delayMs(700);
        expect(await driver.findComponent(ON.text('App language')) !== null).assertTrue();
        AppLanguage.load(ability.context); expect(AppLanguage.choice).assertEqual('en');
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-language-en-tablet.png')).exitCode).assertEqual(0);
        await driver.pressBack();
        await driver.waitForComponent(ON.id('open-settings'), 5000);
        await selectCachedInbox(driver, store, account); await driver.delayMs(500);
        console.info('MAIL_UI_STAGE: find inbox row');
        let row = await driver.waitForComponent(ON.id(`remote-mail-${page.emails[0].id}`).enabled(true), 10000);
        expect(row !== null).assertTrue();
        await driver.delayMs(700);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-inbox-tablet.png')).exitCode).assertEqual(0);
        const rowBounds = await row.getBounds();
        const rowY = Math.round((rowBounds.top + rowBounds.bottom) / 2);
        await driver.swipe(Math.round(rowBounds.right * 0.85), rowY, Math.round(rowBounds.right * 0.25), rowY, 600);
        await driver.delayMs(500);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-swipe-tablet.png')).exitCode).assertEqual(0);
        await (await driver.waitForComponent(ON.id(`swipe-star-${page.emails[0].id}`).enabled(true), 5000)).click();
        await driver.delayMs(800);
        row = await driver.waitForComponent(ON.id(`remote-mail-${page.emails[0].id}`).enabled(true), 10000);
        const starred = await client.readEmail(account.serverId, page.emails[0].id);
        expect(starred?.keywords.includes('$flagged')).assertTrue();
        expect(starred?.keywords.includes('$seen')).assertFalse();
        console.info('MAIL_UI_STAGE: open inbox row');
        expect(row !== null).assertTrue(); await row.click();
        console.info('MAIL_UI_STAGE: find HTML web');
        expect(await driver.waitForComponent(ON.id('html-mail'), 10000) !== null).assertTrue();
        await driver.delayMs(1500);
        await driver.waitForComponent(ON.id('reply-mail').enabled(true), 10000);
        expect((await client.readEmail(account.serverId, page.emails[0].id))?.keywords.includes('$seen')).assertTrue();
        expect(await driver.findComponent(ON.text('Mark unread')) === null).assertTrue();
        expect(await driver.findComponent(ON.text('SCRIPT EXECUTED')) === null).assertTrue();
        const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-html-tablet.png');
        expect(capture.exitCode).assertEqual(0);
        expect(await driver.waitForComponent(ON.text('HTML mail works'), 5000) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('toggle-html')) === null).assertTrue();
        expect((await imageStats()).imageLoads).assertEqual(0);
        await (await driver.waitForComponent(ON.id('load-pictures'), 5000)).click();
        await driver.delayMs(1500);
        expect((await imageStats()).imageLoads > 0).assertTrue();
        expect((await imageStats()).remoteLoads).assertEqual(0);
        const subject = await driver.findComponent(ON.id('reader-subject'));
        const before = await subject.getBounds();
        const scroll = await (await driver.findComponent(ON.id('reader-scroll'))).getBounds();
        const x = Math.round((scroll.left + scroll.right) / 2);
        await driver.swipe(x, Math.round(scroll.top + (scroll.bottom - scroll.top) * 0.8), x, Math.round(scroll.top + (scroll.bottom - scroll.top) * 0.2), 700);
        await driver.delayMs(700);
        const after = await driver.findComponent(ON.id('reader-subject'));
        expect(after === null || (await after.getBounds()).top < before.top).assertTrue();
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-reader-scrolled-tablet.png')).exitCode).assertEqual(0);

        // The tablet keeps the inbox alongside the reader; phones navigate back.
        if (await driver.findComponent(ON.id('compose-mail')) === null) {
          await driver.pressBack();
          await driver.delayMs(700);
        }
        console.info('MAIL_UI_STAGE: find compose');
        const compose = await driver.waitForComponent(ON.id('compose-mail'), 5000);
        expect(compose !== null).assertTrue(); await compose.click();
        expect(await driver.waitForComponent(ON.id('compose-to'), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.text('Tablet composer'), 5000) !== null).assertTrue();
        expect(await (await driver.findComponent(ON.id('compose-subject'))).getText()).assertEqual('Tablet composer');
        expect(await driver.waitForIdle(500, 5000)).assertTrue();
        await driver.delayMs(1500);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-compose-tablet.png')).exitCode).assertEqual(0);
        await (await driver.findComponent(ON.id('compose-more'))).click();
        await (await driver.waitForComponent(ON.text('Outgoing server'), 5000)).click();
        console.info('MAIL_UI_STAGE: find settings');
        const host = await driver.waitForComponent(ON.id('smtp-host'), 5000);
        expect(host !== null).assertTrue(); expect(await host.getText()).assertEqual('localhost');
        await (await driver.waitForComponent(ON.id('save-smtp'), 5000)).click();
        expect(await driver.waitForIdle(500, 5000)).assertTrue();
        console.info('MAIL_UI_STAGE: send fixture');
        await sendWithoutBlocking(driver, store, account, 1);
        await (await driver.waitForComponent(ON.id('compose-mail'), 5000)).click();
        expect(await driver.waitForComponent(ON.id('compose-to'), 5000) !== null).assertTrue();
        await driver.delayMs(500);
        expect(await (await driver.findComponent(ON.id('compose-to'))).getText()).assertEqual('');
        await (await driver.findComponent(ON.id('cancel-compose'))).click();
        await driver.delayMs(700);
        await (await driver.waitForComponent(ON.id(`remote-mail-${page.emails[0].id}`).enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.id('html-mail'), 5000) !== null).assertTrue();
        await driver.delayMs(1000);
        const protectedDraft = new OutgoingDraft(); protectedDraft.id = util.generateRandomUUID();
        protectedDraft.subject = 'Keep existing draft'; protectedDraft.date = Date.now();
        await store.saveOutgoing(account.id, protectedDraft);
        await (await driver.waitForComponent(ON.id('reply-mail'), 5000)).click();
        await (await driver.waitForComponent(ON.text('Reply all'), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Unfinished draft'), 5000) !== null).assertTrue();
        expect((await store.outgoing(account.id))?.id).assertEqual(protectedDraft.id);
        await (await driver.waitForComponent(ON.text('Cancel'), 5000)).click();
        await driver.delayMs(700);
        expect(await driver.findComponent(ON.text('Unfinished draft')) === null).assertTrue();
        await store.clearOutgoing(account.id);
        await (await driver.findComponent(ON.id('reply-mail'))).click();
        await (await driver.waitForComponent(ON.text('Reply all'), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Re: Message 92'), 5000) !== null).assertTrue();
        expect(await (await driver.findComponent(ON.id('compose-to'))).getText()).assertEqual('support@example.test, reader@example.test');
        expect(await (await driver.findComponent(ON.id('compose-cc'))).getText()).assertEqual('copy@example.test');
        expect(await (await driver.findComponent(ON.id('compose-bcc'))).getText()).assertEqual('');
        const reply = await store.outgoing(account.id);
        expect(reply?.inReplyTo.join(',')).assertEqual('92@example.test');
        expect(reply?.references.join(',')).assertEqual('root@example.test,older@example.test,92@example.test');
        await driver.delayMs(1500);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-reply-tablet.png')).exitCode).assertEqual(0);
        await sendWithoutBlocking(driver, store, account, 2);
        await (await driver.waitForComponent(ON.id(`remote-mail-${page.emails[0].id}`).enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.id('html-mail'), 5000) !== null).assertTrue();
        await driver.delayMs(700);
        await (await driver.waitForComponent(ON.id('reply-mail'), 5000)).click();
        await (await driver.waitForComponent(ON.text('Forward'), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Fwd: Message 92'), 5000) !== null).assertTrue();
        const forwardTo = await driver.waitForComponent(ON.id('compose-to'), 5000);
        expect(await forwardTo.getText()).assertEqual('');
        const forward = await store.outgoing(account.id);
        expect(forward?.inReplyTo.length).assertEqual(0); expect(forward?.references.length).assertEqual(0);
        expect(forward?.cc).assertEqual(''); expect(forward?.bcc).assertEqual('');
        expect(forward?.forwardHtml.includes('<strong>bold</strong>')).assertTrue();
        expect(await driver.waitForComponent(ON.id('forward-preview'), 5000) !== null).assertTrue();
        await forwardTo.inputText('forward@example.test');
        await (await driver.findComponent(ON.id('compose-body'))).inputText('Forward note <safe> 日本語');
        await driver.pressBack();
        await driver.delayMs(1500);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-forward-tablet.png')).exitCode).assertEqual(0);
        await sendWithoutBlocking(driver, store, account, 3);

        console.info('MAIL_UI_STAGE: persistent HTML picture consent');
        await ability.showHtmlConsentFixture();
        await driver.waitForComponent(ON.id('consent-message-key'), 5000);
        expect(await (await driver.findComponent(ON.id('consent-message-key'))).getText()).assertEqual('consent-a');
        expect(await driver.waitForComponent(ON.id('load-pictures'), 5000) !== null).assertTrue();
        await driver.waitForIdle(300, 3000);
        const beforeConsent = await imageStats();
        await driver.delayMs(1000);
        expect((await imageStats()).imageLoads).assertEqual(beforeConsent.imageLoads);
        await (await driver.findComponent(ON.id('load-pictures'))).click();
        await driver.delayMs(1500);
        const afterFirstConsent = await imageStats();
        expect(afterFirstConsent.imageLoads > beforeConsent.imageLoads).assertTrue();
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();

        // The same renderer and HTML stay mounted. Only messageKey changes.
        // Removing its watcher must fail this assertion even when HTML matches.
        await (await driver.findComponent(ON.id('switch-consent-message'))).click();
        expect(await driver.waitForComponent(ON.id('load-pictures'), 5000) !== null).assertTrue();
        expect(await (await driver.findComponent(ON.id('consent-message-key'))).getText()).assertEqual('consent-b');
        await driver.delayMs(1500);
        const afterIdentityChange = await imageStats();
        expect(afterIdentityChange.imageLoads).assertEqual(afterFirstConsent.imageLoads);
        expect(afterIdentityChange.remoteLoads).assertEqual(0);
        await (await driver.findComponent(ON.id('load-pictures'))).click();
        await driver.delayMs(1500);
        const afterSecondConsent = await imageStats();
        expect(afterSecondConsent.imageLoads > afterIdentityChange.imageLoads).assertTrue();
        expect(afterSecondConsent.remoteLoads).assertEqual(0);
        console.info('HTML_CONSENT: identical HTML required fresh image permission after message identity changed');

      } finally {
        await ability.context.terminateSelf();
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
