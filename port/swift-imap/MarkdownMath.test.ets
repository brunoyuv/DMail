// Synthetic local rendering, persistence and native MIME validation. No network or SMTP send.
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { Driver, ON, Component } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { OutgoingDraft, SmtpSettings, submitMail } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { typesetEquation } from '../../../main/ets/mail/math/vendor/engine';
import { mathGlyphFixtures } from './MathGlyphFixtures';
import { markdownMathPlan } from '../../../main/ets/mail/math/MarkdownMath';
import { markdownPreview } from '../../../main/ets/mail/math/MarkdownPreview';
import { MailMessageLoader } from '../../../main/ets/mail/MailMessageLoader';
import { navigationAccount, navigationMailbox, navigationMail, NavigationClientFactory, NavigationFixtureState } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

async function required(driver: Driver, id: string): Promise<Component> {
  const value = await driver.waitForComponent(ON.id(id), 5000);
  if (value === null) {
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    await delegator.print('MATH_UI_MISSING: ' + id + '\n');
  }
  expect(value !== null).assertTrue(); return value;
}
export default function tests(ui: boolean = false, operatorFixture: boolean = false): void {
  describe('MarkdownMath', () => {
    if (!ui) { it('offline_html_source_drafts_cached_reading_and_native_mime', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext().getApplicationContext().createModuleContext('entry');
      const text = '# Synthetic math\n\nGreek $\\Sigma$; summation $\\sum$.\n\n$$\\Sigma \\qquad \\sum_{i=1}^{n} i$$\n\nInline $a+b$ and $\\frac{a}{b}+x^2$.\n\n$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$\n\n中文 remains text.\n\nRoots $\\sqrt{x^2+1}$ and $\\int_0^1 x dx$.\n\n$$\\left(\\frac{1}{1+x}\\right)$$';
      for (const fixture of mathGlyphFixtures) {
        const actual = typesetEquation(fixture.source, fixture.display, fixture.renderer);
        expect(actual === fixture.markup).assertTrue();
      }
      await delegator.print('MATH_GLYPHS_PASS: native CommonHTML and MathML match host references exactly\n');
      const formatted = await markdownPreview(text, 'commonhtml');
      expect(formatted.includes('<h1>')).assertTrue();
      expect(formatted.includes('<mjx-container')).assertTrue(); expect(formatted.includes('data:font/woff2;base64,')).assertTrue();
      const nativeMath = await markdownPreview(text, 'mathml');
      expect(nativeMath.includes('<math ')).assertTrue();
      expect(nativeMath.includes('<img')).assertFalse();
      const store = new AccountStore('navigation_ui_test.db'); await store.open(context);
      const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'synthetic-token', 'beta@example.test');
      try {
        expect((await store.mathSettings(account.id)).sendFormat).assertEqual('source');
        await store.saveMathSettings(account.id, { renderWhileReading: true, sendFormat: 'formatted', renderer: 'commonhtml' });
        const draft = new OutgoingDraft(); draft.id = util.generateRandomUUID(); draft.date = Date.now();
        draft.to = 'recipient@example.invalid'; draft.subject = 'Synthetic formula'; draft.text = text;
        await store.prepareNewOutgoing(account.id, draft); await store.saveOutgoing(account.id, draft);
        await store.saveMathSettings(account.id, { renderWhileReading: true, sendFormat: 'source', renderer: 'commonhtml' });
        const reopened = (await store.outgoing(account.id))!;
        expect(reopened.text).assertEqual(text);
        const settings = new SmtpSettings(); settings.endpoint = 'smtps://smtp.example.invalid:465'; settings.username = 'beta@example.test';
        expect((await submitMail(settings, 'beta@example.test', reopened, true)).accepted).assertFalse();
        const mail = navigationMail('Beta', 0, 0, true); mail.textBody = text; mail.htmlBody = null; mail.hasHtmlBody = false;
        await store.mail.saveBoxes(account.id, [navigationMailbox()], false);
        await store.mail.saveView(account.id, 'inbox', [mail]); await store.mail.saveEmail(account.id, mail);
        const loader = new MailMessageLoader(store), client = new NavigationClientFactory().create(account.sessionUrl, { authorization: async () => 'synthetic-token' });
        NavigationFixtureState.reset();
        const first = await loader.open(client, account, mail, 'Show', 'Hide', () => true);
        expect(first.document?.html.includes('<mjx-container')).assertTrue(); expect(first.mail.textBody).assertEqual(text);
        const second = await loader.open(client, account, mail, 'Show', 'Hide', () => true);
        expect(second.document?.savedAt).assertEqual(first.document?.savedAt);
        await store.saveMathSettings(account.id, { renderWhileReading: true, sendFormat: 'source', renderer: 'mathml' });
        const changed = await loader.open(client, account, mail, 'Show', 'Hide', () => true);
        expect(changed.document?.html.includes('<math ')).assertTrue();
        expect(changed.document?.html.includes('<mjx-container')).assertFalse();
        await store.saveMathSettings(account.id, { renderWhileReading: false, sendFormat: 'source', renderer: 'mathml' });
        const original = await loader.open(client, account, mail, 'Show', 'Hide', () => true);
        expect(original.document?.html.includes('<mjx-container')).assertFalse(); expect(original.mail.textBody).assertEqual(text);
        expect(NavigationFixtureState.calls.length).assertEqual(0);
        await store.rememberVisitedAccount(account.id);
        await delegator.print('MATH_CORE_PASS: CommonHTML/MathML, source draft, native MIME validation, renderer cache separation and off toggle\n');
      } finally { await store.close(); }
    });
    }
    if (ui) { it('plain_editor_preview_returns_to_exact_source', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      await delegator.print('MATH_UI_STAGE: create driver\n');
      const driver = Driver.create();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.print('MATH_UI_STAGE: start blank ability\n');
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(await driver.waitForComponent(ON.text('Preparing mail preview'), 5000) !== null).assertTrue();
      // Physical runs must prove the isolated blank page before any wake/swipe.
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8), Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(4000);
      const store = new AccountStore('navigation_ui_test.db'); await store.open(ability.context);
      try {
        await delegator.print('MATH_UI_STAGE: open fixture\n');
        for (const saved of await store.list()) { await store.remove(saved.id); }
        const account = await store.add('https://beta.example.test/session', navigationAccount('Beta'), 'synthetic-token', 'beta@example.test');
        const mail = navigationMail('Beta', 0, 0, true);
        await store.mail.saveBoxes(account.id, [navigationMailbox()], false);
        await store.mail.saveView(account.id, 'inbox', [mail]); await store.mail.saveEmail(account.id, mail);
        await store.saveMathSettings(account.id, { renderWhileReading: true, sendFormat: 'formatted', renderer: 'commonhtml' });
        const draft = new OutgoingDraft(); draft.id = util.generateRandomUUID(); draft.date = Date.now();
        draft.to = 'recipient@example.invalid'; draft.subject = 'Synthetic formula';
        const operators = 'Operators\n\nInline $\\sum_{i=1}^n i$; letter $\\Sigma$.\n\nForced $\\sum\\limits_{i=1}^n i$.\n\n$$\\sum_{i=1}^n i \\qquad \\sum\\nolimits_{i=1}^n i$$\n\n$$\\prod_{i=1}^n x_i + \\bigcup_{i=1}^n A_i$$\n\n$$\\int_0^1 x\\,dx$$\n\n$$\\frac{\\displaystyle\\sum_i x_i}{\\sum_j y_j}$$';
        const screenshotPrefix = operatorFixture ? 'math-operators-' : 'math-preview-';
        draft.text = '# Synthetic math\n\nGreek $\\Sigma$; summation $\\sum$.\n\n$$\\Sigma \\qquad \\sum_{i=1}^{n} i$$\n\nInline $a+b$ and $\\frac{a}{b}+x^2$.\n\n$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$\n\n中文 remains text.\n\nRoots $\\sqrt{x^2+1}$ and $\\int_0^1 x dx$.\n\n$$\\left(\\frac{1}{1+x}\\right)$$';
        if (operatorFixture) { draft.text = operators; }
        await store.prepareNewOutgoing(account.id, draft); await store.saveOutgoing(account.id, draft);
        await store.rememberVisitedAccount(account.id);
        await AppLanguage.set(ability.context, 'en');
        await delegator.print('MATH_UI_STAGE: language set\n');
        ability.resetNavigationFixtureState(); await ability.showNavigationFixture();
        await delegator.print('MATH_UI_STAGE: fixture ready\n');
        await required(driver, 'navigation-fixture-marker'); await (await required(driver, 'compose-mail')).click();
        await delegator.print('MATH_UI_STAGE: composer\n');
        const body = await required(driver, 'compose-body');
        for (let attempt = 0; attempt < 50 && !await body.isEnabled(); attempt++) { await driver.delayMs(50); }
        expect(await body.isEnabled()).assertTrue();
        const source = await body.getOriginalText();
        expect(source).assertEqual(draft.text);
        await (await required(driver, 'compose-more')).click();
        const preview = await driver.waitForComponent(ON.text('Preview message'), 3000); expect(preview !== null).assertTrue(); await preview.click();
        await delegator.print('MATH_UI_STAGE: preview requested\n');
        await required(driver, 'compose-preview'); await driver.delayMs(1200);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/' + screenshotPrefix + 'commonhtml.png')).exitCode).assertEqual(0);
        await (await required(driver, 'close-compose-preview')).click(); await driver.delayMs(300);
        expect(await (await required(driver, 'compose-body')).getOriginalText()).assertEqual(source);
        await store.saveMathSettings(account.id, { renderWhileReading: true, sendFormat: 'formatted', renderer: 'mathml' });
        await (await required(driver, 'compose-more')).click();
        const again = await driver.waitForComponent(ON.text('Preview message'), 3000); expect(again !== null).assertTrue(); await again.click();
        await required(driver, 'compose-preview'); await driver.delayMs(1200);
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/' + screenshotPrefix + 'mathml.png')).exitCode).assertEqual(0);
        await (await required(driver, 'close-compose-preview')).click(); await driver.delayMs(300);
        expect(await (await required(driver, 'compose-body')).getOriginalText()).assertEqual(source);
        await delegator.print('MATH_UI_PASS: both previews render a saved draft and preserve its exact source\n');
      } finally { await store.close(); await delegator.removeAbilityMonitor(monitor); }
    }); }
  });
}
