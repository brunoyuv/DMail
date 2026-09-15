// Exact Unicode expectations cross the shipping Swift IMAP/MIME and NAPI path.
import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON, Rect } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { BODY_DECODER_REVISION } from '../../../main/ets/data/MailCacheModel';
import IMAPTestAbility from '../abilities/IMAPTestAbility';

interface EncodingCase { subject: string; text: string | null; html: string | null; }
interface EncodingSession { mode: string; closed: boolean; }
interface EncodingStats { sessions: EncodingSession[]; active: number; violations: string[]; }
const sender = '山田 太郎';
const htmlText = '中文 café 😀';
const cases: EncodingCase[] = [
  { subject: 'Re: 中文 café 📨 update', text: null, html: '<p>中文 café 😀</p>' },
  { subject: 'Shift_JIS 日本語', text: '日本語', html: null },
  { subject: 'UTF-8 中文', text: '中文', html: null }
];
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('encoding:fixture-password'))}`;
  }
}
async function stats(): Promise<EncodingStats> {
  const request = http.createHttp();
  try { return JSON.parse((await request.request('http://localhost:9760/stats')).result as string) as EncodingStats; }
  finally { request.destroy(); }
}
function exactMail(mail: JmapEmail, fixture: EncodingCase): void {
  expect(mail.subject).assertEqual(fixture.subject);
  expect(mail.from[0].name).assertEqual(sender);
  expect(mail.from[0].email).assertEqual('sender@example.test');
  expect(mail.textBody ?? null).assertEqual(fixture.text);
  expect(mail.htmlBody ?? null).assertEqual(fixture.html);
  expect(mail.bodyEncodingProblem === true).assertFalse();
}
async function visibleHtml(driver: Driver): Promise<void> {
  await driver.waitForComponent(ON.id('html-mail'), 5000);
  await driver.delayMs(700);
  for (let attempt = 0; attempt < 6; attempt++) {
    const pane: Rect = await (await driver.findComponent(ON.id('reader-scroll'))).getBounds();
    const text = await driver.findComponent(ON.text(htmlText).within(ON.id('reader-scroll')));
    if (text !== null) {
      const bounds = await text.getBounds();
      if (bounds.left >= pane.left - 2 && bounds.right <= pane.right + 2 &&
        bounds.top >= pane.top + 2 && bounds.bottom <= pane.bottom - 2 && bounds.bottom > bounds.top) {
        expect(await text.getText()).assertEqual(htmlText);
        return;
      }
    }
    const x = Math.floor((pane.left + pane.right) / 2), height = pane.bottom - pane.top;
    await driver.swipe(x, Math.floor(pane.top + height * 0.8), x, Math.floor(pane.top + height * 0.45), 450);
    await driver.delayMs(250);
  }
  throw new Error('Decoded Unicode HTML is not fully visible in the reader');
}

export default function tests(): void {
  describe('UnicodeMailEncoding', () => {
    it('headers_bodies_render_and_cached_revisit_preserve_unicode', 0, async () => {
      const credentials = new Credentials();
      const core = new NativeImapClient('imaps://localhost:9761', credentials);
      const session = await core.connect();
      const accountId = session.accounts[0].id;
      const boxes = await core.mailboxes(accountId);
      expect(boxes.length).assertEqual(1);
      const page = await core.emailPage(accountId, boxes[0].id);
      expect(page.emails.length).assertEqual(3);
      for (const fixture of cases) {
        const summary = page.emails.find(mail => mail.subject === fixture.subject);
        expect(summary !== undefined).assertTrue();
        expect(summary!.from[0].name).assertEqual(sender);
        const mail = await core.readEmail(accountId, summary!.id);
        expect(mail !== null).assertTrue();
        exactMail(mail!, fixture);
      }
      console.info('ENCODING_NATIVE: exact mixed RFC2047 subject, sender, UTF8 HTML, Shift_JIS and split quoted-printable bodies passed');

      const driver = Driver.create();
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.floor(screen.width / 2), Math.floor(screen.height * 0.8),
        Math.floor(screen.width / 2), Math.floor(screen.height * 0.2), 600);
      await driver.delayMs(5000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      const store = new AccountStore('mail_features_test.db');
      await store.open(ability.context);
      try {
        for (const account of await store.list()) { await store.remove(account.id); }
        const account = await store.add('imaps://localhost:9761', session.accounts[0],
          (await credentials.authorization()).slice(6), 'reader@example.test');
        await AppLanguage.set(ability.context, 'en');
        await ability.showMailFeaturesFixture();
        const htmlSummary = page.emails.find(mail => mail.subject === cases[0].subject)!;
        const rowId = `remote-mail-${htmlSummary.id}`;
        const row = await driver.waitForComponent(ON.id(rowId).enabled(true), 10000);
        expect(row !== null).assertTrue();
        expect(await (await driver.findComponent(ON.text(cases[0].subject).within(ON.id(rowId)))).getText()).assertEqual(cases[0].subject);
        expect(await (await driver.findComponent(ON.text(sender).within(ON.id(rowId)))).getText()).assertEqual(sender);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/encoding-inbox.png')).exitCode).assertEqual(0);
        await row.click();
        await driver.waitForComponent(ON.id('reply-mail').enabled(true), 10000);
        expect(await (await driver.waitForComponent(ON.id('reader-subject'), 5000)).getText()).assertEqual(cases[0].subject);
        expect(await driver.findComponent(ON.text(sender).within(ON.id('reader-scroll'))) !== null).assertTrue();
        await visibleHtml(driver);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/encoding-reader.png')).exitCode).assertEqual(0);
        const cached = await store.mail.email(account.id, htmlSummary.id);
        expect(cached !== null).assertTrue();
        expect(cached!.bodyDecoderRevision).assertEqual(BODY_DECODER_REVISION);
        exactMail(cached!.mail, cases[0]);
        console.info('ENCODING_UI: exact subject, sender and rendered HTML visible in native reader');
        const first = await stats();
        expect(first.active).assertEqual(0);
        await driver.pressBack();
        await (await driver.waitForComponent(ON.id(rowId).enabled(true), 5000)).click();
        await driver.waitForComponent(ON.id('reply-mail').enabled(true), 5000);
        await visibleHtml(driver);
        const repeated = await stats();
        expect(repeated.sessions.length).assertEqual(first.sessions.length);
        expect(repeated.active).assertEqual(0);
        expect(repeated.violations.length).assertEqual(0);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/encoding-cached.png')).exitCode).assertEqual(0);
        console.info('ENCODING_CACHE: current decoded body revisited with zero new IMAP connections');
      } finally {
        await ability.context.terminateSelf();
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
