// No captures or mailbox access. Device CPU is sampled separately by the host.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('HtmlScrollPower', () => {
    it('historical_and_current_renderers_have_identical_bounded_scroll_phases', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const driver = Driver.create();
      // The host brings up this isolated blank page before aa test. No swipe or
      // wake action may target whatever production app was previously visible.
      await ability.hideNavigationFixture();
      await driver.wakeUpDisplay();
      const phase = async (mode: string, name: string, edge: string): Promise<void> => {
        await delegator.print(`POWER_PHASE ${mode} ${name} ${edge} ${Date.now()}\n`);
      };
      const oneWeb = async (): Promise<void> => {
        expect((await driver.findComponents(ON.id('html-mail'))).length).assertEqual(1);
      };
      try {
        for (const mode of ['baseline011', 'current018', 'asyncViewport']) {
          await ability.showHtmlScrollPowerFixture(mode);
          expect(await driver.waitForComponent(ON.text('Synthetic scroll power email'), 10000) !== null).assertTrue();
          let previous = '', stable = 0;
          for (let attempt = 0; attempt < 24 && stable < 3; attempt++) {
            await driver.delayMs(150);
            const current = ability.htmlScrollPowerLoads();
            stable = ability.htmlScrollPowerDocumentCount() > 0 && current === previous ? stable + 1 : 0;
            previous = current;
          }
          expect(stable >= 3).assertTrue();
          expect(ability.htmlScrollPowerLength() > 100000 && ability.htmlScrollPowerLength() * 3 <= 1024 * 1024).assertTrue();
          const settled = ability.htmlScrollPowerLoads();
          await oneWeb();
          const bounds = await (await driver.waitForComponent(ON.id('html-power-scroll'), 3000)).getBounds();
          const closeBounds = await (await driver.waitForComponent(ON.id('html-power-close'), 3000)).getBounds();
          const viewport = display.getDefaultDisplaySync();
          const left = Math.max(0, bounds.left), right = Math.min(viewport.width - 1, bounds.right);
          const top = Math.max(bounds.top, closeBounds.bottom + 8), bottom = Math.min(viewport.height - 32, bounds.bottom);
          const x = Math.round((left + right) / 2);
          const high = Math.round(top + (bottom - top) * 0.22), low = Math.round(top + (bottom - top) * 0.78);
          expect(right > left && bottom - top > 100 && low > high && low < viewport.height).assertTrue();
          await delegator.print(`POWER_READY ${mode} ${Date.now()} length=${ability.htmlScrollPowerLength()} loads=${settled} gesture=fling speed_px_s=16000` +
            ` viewport=${viewport.width}x${viewport.height} x=${x} high=${high} low=${low}\n`);
          await phase(mode, 'idle', 'start');
          await driver.delayMs(5000);
          await phase(mode, 'idle', 'end');
          await phase(mode, 'scroll', 'start');
          const started = Date.now();
          let drags = 0;
          // Repeated rapid flings retain inertia and reverse every fourth
          // gesture. Await only the driver itself; add no pause between flings.
          while (Date.now() - started < 20000 && drags < 400) {
            if (drags % 4 === 3) { await driver.fling({ x, y: high }, { x, y: low }, 80, 16000); }
            else { await driver.fling({ x, y: low }, { x, y: high }, 80, 16000); }
            ++drags;
          }
          const elapsed = Date.now() - started;
          await delegator.print(`POWER_GESTURES ${mode} count=${drags} elapsed_ms=${elapsed}\n`);
          await phase(mode, 'scroll', 'end');
          await phase(mode, 'settled', 'start');
          await driver.delayMs(5000);
          await phase(mode, 'settled', 'end');
          await oneWeb();
          expect(elapsed >= 20000 && drags >= 10).assertTrue();
          expect(ability.htmlScrollPowerEvents() > 0 && ability.htmlScrollPowerMaximum() > 100).assertTrue();
          expect(ability.htmlScrollPowerLoads()).assertEqual(settled);
          const closedAt = Date.now();
          await (await driver.waitForComponent(ON.id('html-power-close'), 1000)).click();
          expect(await driver.waitForComponent(ON.id('html-power-closed'), 3000) !== null).assertTrue();
          const closeDelay = Date.now() - closedAt;
          expect(closeDelay < 3000).assertTrue();
          expect(await driver.findComponent(ON.id('html-mail')) === null).assertTrue();
          await delegator.print(`POWER_RESULT ${mode} ${Date.now()} rows=1500 drags=${drags} elapsed_ms=${elapsed}` +
            ` scroll_events=${ability.htmlScrollPowerEvents()} max_offset_vp=${ability.htmlScrollPowerMaximum()}` +
            ` loads=${ability.htmlScrollPowerLoads()} one_web=true close_ms=${closeDelay}\n`);
          await ability.hideNavigationFixture();
          await driver.delayMs(500);
        }
      } finally {
        await ability.hideNavigationFixture();
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
