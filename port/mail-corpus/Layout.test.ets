// Focused layout checks use public/synthetic mail through the shipping Swift core.
import { describe, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Component, Driver, ON, On, Rect } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import IMAPTestAbility from '../abilities/IMAPTestAbility';

interface LayoutCase { uid: number; name: string; marker: string; }
interface LayoutResult { name: string; html: boolean; inlineImages: number; error: string; }
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('corpus:fixture-password'))}`;
  }
}
function check(condition: boolean, message: string): void {
  if (!condition) { throw new Error(message); }
}
function insideWidth(bounds: Rect, pane: Rect, name: string): void {
  check(bounds.right > bounds.left && bounds.left >= pane.left - 2 && bounds.right <= pane.right + 2,
    `${name} exceeds its pane: ${JSON.stringify(bounds)} in ${JSON.stringify(pane)}`);
}
async function required(driver: Driver, id: string): Promise<Component> {
  const component = await driver.waitForComponent(ON.id(id), 5000);
  check(component !== null, `${id} is missing`);
  return component;
}
async function visibleControl(driver: Driver, id: string, screen: Rect, density: number): Promise<Rect> {
  check((await driver.findComponents(ON.id(id))).length === 1, `${id} must occur once`);
  const bounds = await (await required(driver, id)).getBounds();
  insideWidth(bounds, screen, id);
  check(bounds.top >= screen.top - 2 && bounds.bottom <= screen.bottom + 2, `${id} is vertically clipped`);
  check(bounds.bottom - bounds.top >= 44 * density - 2, `${id} has a short tap target`);
  return bounds;
}
async function toolbarCount(driver: Driver, scope: string, first: Rect, last: Rect, expected: number): Promise<void> {
  let count = 0;
  // Navigation keeps previous pages in its accessibility tree; count only this surface.
  for (const button of await driver.findComponents(ON.type('Button').within(ON.id(scope)))) {
    const bounds = await button.getBounds();
    const center = (bounds.top + bounds.bottom) / 2;
    if (center >= Math.min(first.top, last.top) && center <= Math.max(first.bottom, last.bottom)) { count++; }
  }
  check(count === expected, `Toolbar has ${count} buttons; expected ${expected}`);
}
async function scrollTo(driver: Driver, selector: On, scrollId: string, attempts: number = 12, fullyVisible: boolean = false): Promise<Component> {
  // Small overlapping swipes avoid skipping short HTML markers on the cover screen.
  for (let attempt = 0; attempt <= attempts; attempt++) {
    const pane = await (await required(driver, scrollId)).getBounds();
    const found = await driver.findComponent(selector);
    if (found !== null) {
      const bounds = await found.getBounds();
      if (fullyVisible ? bounds.top >= pane.top + 12 && bounds.bottom <= pane.bottom - 12 :
        bounds.bottom > pane.top && bounds.top < pane.bottom) { return found; }
    }
    check(attempt < attempts, `Content did not become visible in ${scrollId}`);
    const x = Math.floor((pane.left + pane.right) / 2);
    const height = pane.bottom - pane.top;
    check(height > 60, `${scrollId} is too short to scroll`);
    await driver.swipe(x, Math.floor(pane.top + height * 0.80), x, Math.floor(pane.top + height * 0.45), 450);
    await driver.delayMs(200);
  }
  throw new Error('Unreachable scroll result');
}
async function report(results: LayoutResult[]): Promise<void> {
  const request = http.createHttp();
  try {
    expect((await request.request('http://localhost:9760/corpus/result', {
      method: http.RequestMethod.POST, extraData: JSON.stringify(results)
    })).responseCode).assertEqual(200);
  } finally { request.destroy(); }
}

export default function tests(): void {
  describe('FocusedMailLayout', () => {
    it('inbox_composer_and_three_reader_layouts', 0, async () => {
      const select = http.createHttp();
      try {
        expect((await select.request('http://localhost:9760/corpus/batch/0', {
          method: http.RequestMethod.POST
        })).responseCode).assertEqual(200);
      } finally { select.destroy(); }
      const driver = Driver.create();
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      const viewport: Rect = { left: 0, top: 0, right: screen.width, bottom: screen.height };
      const density = screen.densityPixels;
      console.info(`LAYOUT_SCREEN ${screen.width}x${screen.height} density=${density}`);
      await driver.swipe(Math.floor(screen.width / 2), Math.floor(screen.height * 0.8),
        Math.floor(screen.width / 2), Math.floor(screen.height * 0.2), 600);
      // DEVICE_UNLOCKED credential assets become available shortly after cold boot.
      await driver.delayMs(5000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      const store = new AccountStore('mail_features_test.db');
      await store.open(ability.context);
      const results: LayoutResult[] = [];
      const capture = async (name: string): Promise<void> => {
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/layout-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        for (const account of await store.list()) { await store.remove(account.id); }
        const credentials = new Credentials();
        const client = new NativeImapClient('imaps://localhost:9761', credentials);
        const session = await client.connect();
        const account = await store.add('imaps://localhost:9761', session.accounts[0],
          (await credentials.authorization()).slice(6), 'a.long.account.for.compact.layout@example.test');
        const page = await client.emailPage(account.serverId, (await client.mailboxes(account.serverId))[0].id);
        await AppLanguage.set(ability.context, 'en');
        await ability.showMailFeaturesFixture();
        await driver.waitForComponent(ON.id('compose-mail').enabled(true), 10000);
        await driver.delayMs(500);
        const compose = await visibleControl(driver, 'compose-mail', viewport, density);
        const mailboxes = await visibleControl(driver, 'open-mailboxes', viewport, density);
        check(compose.right <= mailboxes.left + 2, 'Inbox toolbar buttons overlap');
        await toolbarCount(driver, 'inbox-actions', compose, mailboxes, 2);
        const filter = await (await required(driver, 'filter-unread')).getBounds();
        const identity = await (await required(driver, 'inbox-account')).getBounds();
        const listPane = await (await required(driver, 'mail-list')).getBounds();
        insideWidth(filter, listPane, 'Unread filter');
        insideWidth(identity, listPane, 'Account label');
        check(identity.right <= filter.left + 2, 'Account label overlaps unread filter');
        await capture('inbox');

        await (await required(driver, 'compose-mail')).click();
        await required(driver, 'compose-to');
        await driver.delayMs(400);
        const cancel = await visibleControl(driver, 'cancel-compose', viewport, density);
        const more = await visibleControl(driver, 'compose-more', viewport, density);
        const send = await visibleControl(driver, 'send-mail', viewport, density);
        check(cancel.right <= more.left + 2 && more.right <= send.left + 2, 'Composer toolbar buttons overlap');
        await toolbarCount(driver, 'compose-panel', cancel, send, 3);
        const disclosure = await visibleControl(driver, 'expand-addresses', viewport, density);
        check(disclosure.right - disclosure.left <= 760 * density + 2, 'Composer exceeds reading measure');
        insideWidth(await (await required(driver, 'compose-subject')).getBounds(), viewport, 'Subject field');
        await capture('compose');
        await (await required(driver, 'expand-addresses')).click();
        await required(driver, 'compose-cc');
        await required(driver, 'compose-bcc');
        const from = await scrollTo(driver, ON.id('compose-from'), 'compose-scroll', 4);
        const fromBounds = await from.getBounds();
        insideWidth(fromBounds, await (await required(driver, 'compose-scroll')).getBounds(), 'From row');
        check(fromBounds.right - fromBounds.left <= 760 * density + 2, 'Expanded composer exceeds reading measure');
        await capture('compose-expanded');
        await (await required(driver, 'cancel-compose')).click();
        await driver.delayMs(350);

        const cases: LayoutCase[] = [
          { uid: 118, name: 'large-pdf.eml', marker: 'PDF attachment message' },
          { uid: 117, name: 'wide-newsletter.eml', marker: 'RIGHT EDGE' },
          { uid: 112, name: 'multipart-related-mhtml.txt', marker: 'def' }
        ];
        for (const fixture of cases) {
          const result: LayoutResult = { name: fixture.name, html: false, inlineImages: 0, error: '' };
          let opened = false;
          try {
            const summary = page.emails.find(item => item.subject === fixture.name);
            check(summary !== undefined, `Missing fixture ${fixture.name}`);
            const mail = await client.readEmail(account.serverId, summary!.id);
            result.html = !!mail?.htmlBody;
            result.inlineImages = (mail?.htmlBody?.match(/data:image\//g) || []).length;
            check(result.html, `${fixture.name} has no HTML`);
            if (fixture.uid !== 118) { check(result.inlineImages > 0, `${fixture.name} lost its inline image`); }
            const row = await scrollTo(driver, ON.id(`remote-mail-${summary!.id}`).enabled(true), 'mail-list');
            await row.click(); opened = true;
            await driver.waitForComponent(ON.id('reply-mail').enabled(true), 10000);
            await visibleControl(driver, 'reply-mail', viewport, density);
            const title = await required(driver, 'reader-subject');
            expect(await title.getText()).assertEqual(fixture.name);
            const before = await title.getBounds();
            const pane = await (await required(driver, 'reader-scroll')).getBounds();
            const column = await (await required(driver, 'reader-column')).getBounds();
            insideWidth(column, pane, 'Reader column');
            check(column.right - column.left <= 760 * density + 2, 'Reader column exceeds reading measure');
            check(Math.abs((column.left + column.right) - (pane.left + pane.right)) <= 4,
              'Reader column is not centered in its pane');
            insideWidth(before, pane, 'Reader subject');
            check(before.right - before.left <= 760 * density + 2, 'Reader header exceeds reading measure');
            await visibleControl(driver, 'reader-details-toggle', viewport, density);
            if (fixture.uid === 118) {
              await (await required(driver, 'reader-details-toggle')).click();
              const details = await required(driver, 'reader-details');
              insideWidth(await details.getBounds(), pane, 'Reader details');
              await (await required(driver, 'reader-details-toggle')).click();
              await driver.delayMs(200);
              check(await driver.findComponent(ON.id('reader-details')) === null, 'Reader details did not collapse');
            }
            await driver.delayMs(900);
            await capture(`${fixture.uid}`);
            if (fixture.uid === 118) {
              const attachment = await scrollTo(driver, ON.id('attachment-2'), 'reader-scroll', 4);
              insideWidth(await attachment.getBounds(), pane, 'PDF attachment row');
              // ArkWeb can expose an AX marker before its pixels enter the
              // visible scroll area. Capture the body after a real scroll.
              const x = Math.floor((pane.left + pane.right) / 2);
              await driver.swipe(x, Math.floor(pane.top + (pane.bottom - pane.top) * 0.8),
                x, Math.floor(pane.top + (pane.bottom - pane.top) * 0.35), 450);
              await driver.delayMs(300);
            }
            const web = await scrollTo(driver, ON.id('html-mail'), 'reader-scroll', 6);
            const webBounds = await web.getBounds();
            insideWidth(webBounds, pane, 'HTML viewport');
            check(webBounds.right - webBounds.left <= 760 * density + 2, 'HTML exceeds reading measure');
            const marker = await scrollTo(driver, ON.text(fixture.marker), 'reader-scroll', 12, true);
            insideWidth(await marker.getBounds(), pane, `${fixture.name} body marker`);
            await capture(`${fixture.uid}-body`);
            if (fixture.uid === 117) {
              const x = Math.floor((pane.left + pane.right) / 2);
              await driver.swipe(x, Math.floor(pane.top + (pane.bottom - pane.top) * 0.8),
                x, Math.floor(pane.top + (pane.bottom - pane.top) * 0.45), 450);
              await driver.delayMs(250);
              const after = await driver.findComponent(ON.id('reader-subject'));
              check(after === null || (await after.getBounds()).top < before.top - 2,
                'Reader header did not scroll with the HTML body');
              // Continue through the signature, long link and quote to prove the end is reachable.
              const end = await scrollTo(driver, ON.text('NEWSLETTER END'), 'reader-scroll', 18, true);
              insideWidth(await end.getBounds(), pane, 'Newsletter end');
              await capture('117-end');
            }
          } catch (error) { result.error = (error as Error).message; }
          results.push(result);
          await report(results);
          if (opened) {
            const list = await driver.findComponent(ON.id('mail-list'));
            const reader = await driver.findComponent(ON.id('reader-scroll'));
            const split = list !== null && reader !== null &&
              (await list.getBounds()).right <= (await reader.getBounds()).left + 2;
            // The tablet's visible inbox selects the next message directly.
            // System Back at its root would dismiss the fixture ability.
            if (!split) { await driver.pressBack(); await driver.delayMs(300); }
          }
        }
        console.info(`LAYOUT_RESULTS ${JSON.stringify(results)}`);
        expect(results.filter(item => item.error !== '').map(item => `${item.name}: ${item.error}`).join('; ')).assertEqual('');
      } finally {
        await ability.context.terminateSelf();
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
