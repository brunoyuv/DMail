// No captures or mailbox access. Device CPU is sampled separately by the host.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('HtmlPictureScroll', () => {
    it('cached_pictures_stay_saved_during_rapid_scroll_and_missing_images_wait_for_retry', 0, async () => {
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
        await delegator.print(`PICTURE_POWER_COUNTS ${mode} ${name} ${edge} ${Date.now()} ${ability.htmlPictureScrollCounts()}\n`);
      };
      const oneWeb = async (): Promise<void> => {
        expect((await driver.findComponents(ON.id('html-mail'))).length).assertEqual(1);
      };
      try {
        for (const mode of ['baseline018', 'current019']) {
          await ability.showHtmlPictureScrollFixture(mode);
          expect(await driver.waitForComponent(ON.text('Synthetic picture scroll email'), 10000) !== null).assertTrue();
          let previous = '', stable = 0;
          for (let attempt = 0; attempt < 24 && stable < 3; attempt++) {
            await driver.delayMs(150);
            await ability.htmlPictureScrollIdle();
            const current = ability.htmlScrollPowerLoads() + ':' + ability.htmlPictureScrollCounts();
            stable = ability.htmlScrollPowerDocumentCount() > 0 && current === previous ? stable + 1 : 0;
            previous = current;
          }
          expect(stable >= 3).assertTrue();
          expect(ability.htmlScrollPowerLength() > 100000 && ability.htmlScrollPowerLength() * 3 <= 1024 * 1024).assertTrue();
          expect(await ability.htmlPictureScrollCacheIntact()).assertTrue();
          expect(ability.htmlPictureScrollGoodRequests()).assertEqual(20);
          expect(ability.htmlPictureScrollMissingRequests() >= 2).assertTrue();
          expect(await driver.findComponent(ON.id('refresh-pictures')) !== null).assertTrue();
          if (mode === 'current019') { expect(ability.htmlPictureScrollTrackerRequests()).assertEqual(0); }
          const missingBefore = ability.htmlPictureScrollMissingRequests();
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
          await ability.htmlPictureScrollIdle();
          expect(ability.htmlPictureScrollGoodRequests()).assertEqual(20);
          expect(await ability.htmlPictureScrollCacheIntact()).assertTrue();
          if (mode === 'current019') {
            expect(ability.htmlPictureScrollMissingRequests()).assertEqual(missingBefore);
            expect(ability.htmlPictureScrollTrackerRequests()).assertEqual(0);
          }
          await delegator.print(`PICTURE_POWER_RESULT ${mode} ${Date.now()} images=20 decoded_rgba_bytes=28800000 ` +
            `saved_bytes_and_timestamps_intact=true ${ability.htmlPictureScrollCounts()}\n`);
          const closedAt = Date.now();
          await (await driver.waitForComponent(ON.id('html-power-close'), 1000)).click();
          let closedVisible = false;
          try { closedVisible = await driver.waitForComponent(ON.id('html-power-closed'), 3000) !== null; }
          catch (_) { /* Fixed timestamps below distinguish UI latency from driver query failure. */ }
          const closeDelay = Date.now() - closedAt;
          const tapMs = ability.htmlPictureScrollCloseTapMs(), visibleMs = ability.htmlPictureScrollCloseVisibleMs();
          await delegator.print(`PICTURE_POWER_CLOSE ${mode} driver_ms=${closeDelay} tap_epoch_ms=${tapMs} ` +
            `visible_epoch_ms=${visibleMs} native_ms=${tapMs > 0 && visibleMs >= tapMs ? visibleMs - tapMs : -1} ` +
            `closed_found=${closedVisible}\n`);
          expect(closedVisible).assertTrue();
          expect(tapMs > 0 && visibleMs >= tapMs).assertTrue();
          expect(closeDelay < 3000).assertTrue();
          expect(await driver.findComponent(ON.id('html-mail')) === null).assertTrue();
          await delegator.print(`POWER_RESULT ${mode} ${Date.now()} rows=1500 drags=${drags} elapsed_ms=${elapsed}` +
            ` scroll_events=${ability.htmlScrollPowerEvents()} max_offset_vp=${ability.htmlScrollPowerMaximum()}` +
            ` loads=${ability.htmlScrollPowerLoads()} one_web=true close_ms=${closeDelay}\n`);
          await ability.closeHtmlPictureScrollFixture();
          await driver.delayMs(500);
        }
      } finally {
        await ability.closeHtmlPictureScrollFixture();
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
