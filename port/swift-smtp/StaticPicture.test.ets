// Fixed synthetic HTML and loopback HTTP; no physical screenshots or production data.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import deviceInfo from '@ohos.deviceInfo';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('StaticPicture', () => {
    it('resumes_every_page_and_body_before_opening_then_reads_saved_html_only', 0, async () => {
      const started = Date.now();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      // Visual assertions are authorized only for this x86 emulator fixture.
      expect(deviceInfo.abiList.includes('x86_64')).assertTrue();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      // The launcher may already own this foreground ability. The monitor only
      // observes onCreate, so reuse that verified instance instead of waiting
      // for a creation event that has already happened.
      let existing: EntryAbility | undefined;
      try {
        const current = await delegator.getCurrentTopAbility() as EntryAbility;
        if (current.context.abilityInfo.name === 'EntryAbility' &&
          current.context.applicationInfo.name === 'org.thunderbird.harmony.imaptest') {
          existing = current;
        }
      } catch (_) { /* A not-yet-created ability is observed by the monitor. */ }
      const ability = existing || await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.abilityInfo.name).assertEqual('EntryAbility');
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const driver = Driver.create();
      // The isolated blank ability is selected before any wake/unlock gesture.
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(3000);
      const counts = async (expected: string): Promise<void> => {
        for (let attempt = 0; attempt < 100 && ability.staticPictureRequestCounts() !== expected; attempt++) {
          await driver.delayMs(100);
        }
        expect(ability.staticPictureRequestCounts()).assertEqual(expected);
        expect(ability.staticPictureNonContentRequests()).assertEqual(0);
      };
      const loads = async (expected: string): Promise<void> => {
        for (let attempt = 0; attempt < 40 && ability.staticPictureLoadCounts() !== expected; attempt++) {
          await driver.delayMs(100);
        }
        expect(ability.staticPictureLoadCounts()).assertEqual(expected);
      };
      const cache = async (count: number): Promise<void> => {
        for (let attempt = 0; attempt < 40 && !await ability.staticPictureCacheIntact(count); attempt++) {
          await driver.delayMs(100);
        }
        expect(await ability.staticPictureCacheIntact(count)).assertTrue();
      };
      const web = async (): Promise<void> => {
        expect(await driver.waitForComponent(ON.id('html-mail'), 5000) !== null).assertTrue();
        expect((await driver.findComponents(ON.id('html-mail'))).length).assertEqual(1);
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();
      };
      const capture = async (name: string): Promise<void> => {
        ability.staticPictureReturnToTop();
        expect(await driver.waitForComponent(ON.text('Synthetic static pictures'), 5000) !== null).assertTrue();
        await driver.delayMs(500);
        await web();
        const bounds = await (await driver.waitForComponent(ON.id('html-mail'), 3000)).getBounds();
        await delegator.print(`STATIC_PICTURE_BOUNDS: ${JSON.stringify({ name, bounds })}\n`);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/static-picture-${name}.png`)).exitCode).assertEqual(0);
      };
      const saved = async (expectedLoads: string): Promise<void> => {
        await loads(expectedLoads); await web(); await cache(1);
        expect(await ability.staticPictureDocumentIntact()).assertTrue();
        expect(ability.staticPictureWorkCounts()).assertEqual('7,7,1');
        expect(ability.staticPictureSyncCounts()).assertEqual('pages=0,3,6 checkpoint=2/7 saved=7/7');
        expect(await driver.findComponent(ON.id('snapshot-loading')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('refresh-pictures')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('picture-failure-summary')) === null).assertTrue();
      };
      const frozen = async (expectedLoads: string, expectedRequests: string): Promise<void> => {
        await web();
        const bounds = await (await driver.waitForComponent(ON.id('static-picture-scroll'), 3000)).getBounds();
        const x = Math.round((bounds.left + bounds.right) / 2);
        const top = Math.round(bounds.top + (bounds.bottom - bounds.top) * 0.25);
        const bottom = Math.round(bounds.top + (bounds.bottom - bounds.top) * 0.8);
        for (let drag = 0; drag < 4; drag++) { await driver.swipe(x, bottom, x, top, 1800); }
        await driver.delayMs(300);
        expect(ability.staticPictureMaximumScroll() > 100).assertTrue();
        ability.staticPictureForeground(false); await driver.delayMs(300);
        ability.staticPictureForeground(true); await driver.delayMs(700);
        expect(ability.staticPictureLoadCounts()).assertEqual(expectedLoads);
        await counts(expectedRequests); await web();
        expect(ability.staticPictureWorkCounts()).assertEqual('7,7,1');
        expect(ability.staticPictureSyncCounts()).assertEqual('pages=0,3,6 checkpoint=2/7 saved=7/7');
        expect(await ability.staticPictureDocumentIntact()).assertTrue();
        ability.staticPictureReturnToTop(); await driver.delayMs(300);
      };
      try {
        await AppLanguage.set(ability.context, 'en');
        // The ability stays blank while sync checkpoints at two bodies, closes
        // and reopens encrypted storage, then saves every message on all pages.
        const syncing = ability.showStaticPictureFixture(); syncing.catch(() => {});
        await counts('1,1,1');
        expect(await driver.findComponent(ON.id('html-mail')) === null).assertTrue();
        expect(ability.staticPictureLoadCounts()).assertEqual('0,0');
        expect(ability.staticPictureSavedDocumentReady()).assertFalse();
        expect(ability.staticPictureWorkCounts()).assertEqual('7,7,1');
        expect(ability.staticPictureSyncCounts()).assertEqual('pages=0,3,6 checkpoint=2/7 saved=0/7');
        ability.releaseStaticPictures(); await syncing;
        // open() sealed all sources and recreated AccountStore before returning.
        await saved('1,1'); await counts('1,1,1'); await capture('initial');
        await frozen('1,1', '1,1,1'); await capture('scrolled');
        await ability.reopenStaticPictureUnavailable();
        await saved('2,2'); await counts('1,1,1'); await capture('reopened');
        await frozen('2,2', '1,1,1'); await capture('reopened-scrolled');
        expect(Date.now() - started < 90000).assertTrue();
        await delegator.print('STATIC_PICTURE_RESULT: real sync resumed after worker and encrypted-store restart at 2 of 7 bodies, then saved all 7 messages across 3 pages before first reader; all sources offline before mount; opening and reopening add zero body requests, scans, batches or HTTP; broken images remain broken; scroll and foreground add no document mounts or requests; all saved bodies, HTML, image bytes and timestamps remain identical; final requests=1,1,1 work=7,7,1 and non-content=0\n');
      } finally {
        await delegator.print(`STATIC_PICTURE_COUNTS: requests=${ability.staticPictureRequestCounts()} non_content=${ability.staticPictureNonContentRequests()} loads=${ability.staticPictureLoadCounts()} work=${ability.staticPictureWorkCounts()} scroll_max=${ability.staticPictureMaximumScroll()}\n`);
        await delegator.print(`STATIC_PICTURE_TRACE: ${ability.staticPictureTrace()}\n`);
        await delegator.print(`STATIC_PICTURE_SYNC: ${ability.staticPictureSyncCounts()}\n`);
        await ability.closeStaticPictureFixture();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
