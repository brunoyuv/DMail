// Actual user gestures exercise target=_blank handling and local anchors.
// The main-HAP injected opener records URLs without opening a browser.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('HtmlLink', () => {
    it('blank_target_opens_once_and_fragment_stays_in_the_same_email', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(1000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const capture = async (name: string): Promise<void> => {
        await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/html-link-${name}.png`);
      };
      const rendered = async (): Promise<void> => {
        expect(await driver.findComponent(ON.id('html-link-fixture')) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('html-mail')) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('Synthetic link email')) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('Local destination stays in email')) !== null).assertTrue();
      };
      try {
        await ability.showHtmlLinkFixture();
        const link = await driver.waitForComponent(ON.text('Open synthetic website'), 10000);
        expect(ability.htmlLinkOpenCount()).assertEqual(0);
        await link.click();
        for (let attempt = 0; attempt < 30 && ability.htmlLinkOpenCount() === 0; attempt++) {
          await driver.delayMs(100);
        }
        // Leave time for a second navigation callback to reveal a duplicate.
        await driver.delayMs(400);
        expect(ability.htmlLinkOpenCount()).assertEqual(1);
        expect(ability.htmlLinkLastUrl()).assertEqual('https://links.example.test/page?x=1&y=two#section');
        await rendered();
        await (await driver.waitForComponent(ON.text('Jump inside this email'), 3000)).click();
        await driver.delayMs(500);
        expect(ability.htmlLinkOpenCount()).assertEqual(1);
        await rendered();
        await delegator.print('HTML_LINK_RESULT: target=_blank user tap reached injected opener exactly once with intact query/fragment; local anchor stayed in the rendered email; no external browser or mail service invoked\n');
        await ability.showLongHtmlLinkFixture();
        expect(await driver.waitForComponent(ON.text('Synthetic long email'), 10000) !== null).assertTrue();
        expect(ability.htmlLinkLength() > 100000 && ability.htmlLinkLength() * 3 <= 1024 * 1024).assertTrue();
        let previous = '', stable = 0;
        for (let attempt = 0; attempt < 30 && stable < 3; attempt++) {
          await driver.delayMs(150);
          const current = ability.htmlLinkLoadSummary();
          stable = ability.htmlLinkDocumentCount() > 0 && current === previous ? stable + 1 : 0;
          previous = current;
        }
        expect(stable >= 3).assertTrue();
        const settled = ability.htmlLinkLoadSummary();
        const scroll = await driver.waitForComponent(ON.id('html-link-scroll'), 3000);
        const bounds = await scroll.getBounds();
        const viewport = display.getDefaultDisplaySync();
        const closeBounds = await (await driver.waitForComponent(ON.id('html-link-close'), 3000)).getBounds();
        const left = Math.max(0, bounds.left), right = Math.min(viewport.width - 1, bounds.right);
        const top = Math.max(bounds.top, closeBounds.bottom + 8), bottom = Math.min(viewport.height - 32, bounds.bottom);
        const x = Math.round((left + right) / 2);
        const high = Math.round(top + (bottom - top) * 0.22);
        const low = Math.round(top + (bottom - top) * 0.78);
        const webBounds = await (await driver.waitForComponent(ON.id('html-mail'), 3000)).getBounds();
        const columnBounds = await (await driver.waitForComponent(ON.id('html-link-reader-column'), 3000)).getBounds();
        await delegator.print(`HTML_LONG_GEOMETRY: ${JSON.stringify({ screenWidth: viewport.width, screenHeight: viewport.height,
          scroll: bounds, web: webBounds, column: columnBounds, close: closeBounds, x: x, high: high, low: low })}; ` +
          `loads=${settled}; ${ability.htmlLinkDiagnostics()}\n`);
        await capture('long-before');
        expect(right > left && bottom - top > 100 && low > high && low < viewport.height).assertTrue();
        const dragStarted = Date.now();
        let drags = 0;
        while (Date.now() - dragStarted < 11000 && drags < 60) {
          if (drags % 4 === 3) { await driver.swipe(x, high, x, low, 600); }
          else { await driver.swipe(x, low, x, high, 600); }
          ++drags;
        }
        const dragDuration = Date.now() - dragStarted;
        await delegator.print(`HTML_LONG_SCROLL: drags=${drags},duration=${dragDuration}ms,loads=${ability.htmlLinkLoadSummary()}; ` +
          `${ability.htmlLinkDiagnostics()}\n`);
        await capture('long-after');
        expect(dragDuration >= 10000 && drags >= 4).assertTrue();
        expect(ability.htmlLinkScrollEvents() > 0 && ability.htmlLinkScrollMaximum() > 100).assertTrue();
        await driver.delayMs(400);
        expect(ability.htmlLinkLoadSummary()).assertEqual(settled);
        expect(ability.htmlLinkOpenCount()).assertEqual(0);
        // Tap the native control immediately after another moving gesture.
        await driver.swipe(x, low, x, high, 600);
        const closedAt = Date.now();
        await (await driver.waitForComponent(ON.id('html-link-close'), 1000)).click();
        expect(await driver.waitForComponent(ON.id('html-link-closed'), 3000) !== null).assertTrue();
        const closeDelay = Date.now() - closedAt;
        expect(closeDelay < 3000).assertTrue();
        expect(await driver.findComponent(ON.id('html-mail')) === null).assertTrue();
        await delegator.print(`HTML_LONG_RESULT: 1500 rows; ${ability.htmlLinkLength()} UTF-16 units; settled controller/document loads=${settled}; ` +
          `${drags} drags over ${dragDuration}ms; scroll events=${ability.htmlLinkScrollEvents()}, max offset=${ability.htmlLinkScrollMaximum()}vp; ` +
          `no reloads during drags; native Close completed in ${closeDelay}ms\n`);
      } catch (error) {
        await delegator.print(`HTML_LINK_FAILURE: loads=${ability.htmlLinkLoadSummary()}; ${ability.htmlLinkDiagnostics()}\n`);
        await capture('failure');
        throw error as Error;
      } finally {
        await ability.hideNavigationFixture();
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
