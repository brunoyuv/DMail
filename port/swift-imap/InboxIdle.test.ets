// Shipping ConnectedMail, on-demand loader and encrypted cache; synthetic mail
// and bundled PNGs only. Performance sampling is owned by the bounded host runner.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import deviceInfo from '@ohos.deviceInfo';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('InboxIdle', () => {
    it('headers_stay_idle_until_selection_and_fixed_picture_html_survives_fast_scroll_and_background', 0, async () => {
      expect(deviceInfo.abiList.includes('arm64') || deviceInfo.abiList.includes('aarch64') || deviceInfo.abiList.includes('x86_64')).assertTrue();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      let existing: EntryAbility | undefined;
      try {
        const current = await delegator.getCurrentTopAbility() as EntryAbility;
        if (current.context.abilityInfo.name === 'EntryAbility' &&
          current.context.applicationInfo.name === 'org.thunderbird.harmony.imaptest') { existing = current; }
      } catch (_) { /* A newly creating isolated ability is observed below. */ }
      const ability = existing || await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const driver = Driver.create();
      // The host has already foregrounded the isolated blank page. No wake or
      // swipe may act on production mail, and the fixture preserves tablet split.
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(1500);
      const counts = (): number[] => ability.inboxIdleCounts().split(',').map(value => Number(value));
      const work = (): string => counts().slice(0, 5).join(',');
      const phase = async (name: string, edge: string): Promise<void> => {
        await delegator.print(`DEMAND_POWER_PHASE ${name} ${edge} ${Date.now()}\n`);
        await delegator.print(`DEMAND_POWER_COUNTS ${name} ${edge} ${Date.now()} ${ability.inboxIdleCounts()}\n`);
      };
      let background = false;
      try {
        await AppLanguage.set(ability.context, 'en');
        const storageProof = await ability.inboxIdleLargeRowProof();
        await delegator.print(`DEMAND_POWER_RDB_BOUNDARY ${storageProof}\n`);
        expect(storageProof.includes('characters=3145728')).assertTrue();
        expect(storageProof.includes('direct_read=false')).assertTrue();
        await ability.showInboxIdleFixture();
        expect(await driver.waitForComponent(ON.id('inbox-idle-fixture-marker'), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.id('remote-mail-idle-00'), 10000) !== null).assertTrue();
        await driver.delayMs(1500);
        expect(work()).assertEqual('0,0,0,0,0');
        expect(await driver.findComponent(ON.id('html-mail')) === null).assertTrue();
        await phase('idle', 'start'); await driver.delayMs(10000); await phase('idle', 'end');
        expect(work()).assertEqual('0,0,0,0,0');

        // An actual arrival-bus/header refresh changes the visible first page
        // but does not admit any of its17 bodies into automatic sync.
        const beforeRefresh = counts()[5]; await phase('refresh', 'start');
        await (await driver.waitForComponent(ON.id('inbox-idle-navigation'), 3000)).click();
        for (let attempt = 0; attempt < 60 && counts()[5] === beforeRefresh; attempt++) { await driver.delayMs(100); }
        expect(counts()[5] > beforeRefresh).assertTrue();
        await (await driver.waitForComponent(ON.id('mail-list'), 3000)).scrollToTop(1000);
        const selected = await driver.waitForComponent(ON.id('remote-mail-idle-16'), 5000);
        expect(selected !== null).assertTrue(); await driver.delayMs(1000);
        expect(work()).assertEqual('0,0,0,0,0'); await phase('refresh', 'end');

        await phase('open', 'start'); await selected.click();
        expect(await driver.waitForComponent(ON.id('html-mail'), 15000) !== null).assertTrue();
        for (let attempt = 0; attempt < 60 && ability.inboxIdleCompleted() !== 1; attempt++) { await driver.delayMs(100); }
        expect(work()).assertEqual('0,1,0,1,1');
        expect(await ability.inboxIdleSealAndVerify()).assertTrue();
        expect(await driver.findComponent(ON.id('body-not-saved')) === null).assertTrue();
        await driver.delayMs(2500); await phase('open', 'end');
        const savedWork = work();
        const scroll = await driver.waitForComponent(ON.id('reader-scroll'), 3000);
        expect(scroll !== null).assertTrue();
        const bounds = await scroll.getBounds();
        const left = Math.max(0, bounds.left), right = Math.min(screen.width - 1, bounds.right);
        const top = Math.max(0, bounds.top), bottom = Math.min(screen.height - 32, bounds.bottom);
        const x = Math.round((left + right) / 2);
        const high = Math.round(top + (bottom - top) * 0.22), low = Math.round(top + (bottom - top) * 0.78);
        expect(right > left && low - high > 100).assertTrue();
        await delegator.print('DEMAND_POWER_READY images=20 decoded_rgba_bytes=28800000 paragraphs=1200 gesture=fling speed_px_s=16000\n');
        await phase('scroll', 'start'); const started = Date.now(); let gestures = 0;
        while (Date.now() - started < 15000 && gestures < 300) {
          if (gestures % 4 === 3) { await driver.fling({ x, y: high }, { x, y: low }, 80, 16000); }
          else { await driver.fling({ x, y: low }, { x, y: high }, 80, 16000); }
          gestures++;
        }
        const elapsed = Date.now() - started;
        await phase('scroll', 'end'); expect(elapsed >= 15000 && gestures >= 10).assertTrue();
        expect(work()).assertEqual(savedWork);
        await delegator.print(`DEMAND_POWER_GESTURES count=${gestures} elapsed_ms=${elapsed}\n`);
        await phase('settled', 'start'); await driver.delayMs(10000); await phase('settled', 'end');
        expect(work()).assertEqual(savedWork);

        // Scheduling the isolated ability's lifecycle avoids Home/Recents and
        // does not inspect whatever the OS displays behind this synthetic app.
        ability.inboxIdleSetForeground(false);
        await delegator.doAbilityBackground(ability); background = true;
        await phase('background', 'start'); await driver.delayMs(10000); await phase('background', 'end');
        expect(work()).assertEqual(savedWork);
        await delegator.doAbilityForeground(ability); background = false;
        ability.inboxIdleSetForeground(true); await driver.delayMs(1000);
        await (await driver.waitForComponent(ON.id('reader-back'), 5000)).click(); await driver.delayMs(500);
        await (await driver.waitForComponent(ON.id('mail-list'), 3000)).scrollToTop(1000);
        await (await driver.waitForComponent(ON.id('remote-mail-idle-16'), 3000)).click();
        expect(await driver.waitForComponent(ON.id('html-mail'), 5000) !== null).assertTrue();
        expect(work()).assertEqual(savedWork); expect(counts()[6]).assertEqual(0);
        expect(ability.inboxIdleBodyTimes().split(',').length).assertEqual(1);
        // Reopen the actual encrypted AccountStore with the synthetic transport
        // sealed; raw body, prepared HTML and inline pictures must survive it.
        await ability.reopenInboxIdleFixture();
        await (await driver.waitForComponent(ON.id('mail-list'), 5000)).scrollToTop(1000);
        await (await driver.waitForComponent(ON.id('remote-mail-idle-16'), 3000)).click();
        expect(await driver.waitForComponent(ON.id('html-mail'), 10000) !== null).assertTrue();
        expect(work()).assertEqual(savedWork); expect(counts()[6]).assertEqual(0);
        expect(await ability.inboxIdleSealAndVerify()).assertTrue();
        await delegator.print(`DEMAND_POWER_STORAGE ${await ability.inboxIdleStorageProof()}\n`);
        await delegator.print(`DEMAND_POWER_RESULT counts=${ability.inboxIdleCounts()} headers=17 bodies=1 documents=1 images=20 ` +
          `idle_ms=10000 scroll_ms=${elapsed} settled_ms=10000 background_ms=10000 cached_reopen=true storage_reopen=true sealed_source=true\n`);
      } catch (error) {
        await delegator.print(`DEMAND_POWER_FAILURE at=${Date.now()} counts=${ability.inboxIdleCounts()}\n`);
        throw error as Error;
      } finally {
        if (background) { await delegator.doAbilityForeground(ability).catch(() => {}); }
        await ability.closeInboxIdleFixture();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
