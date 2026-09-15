// Synthetic loopback pictures: three visible URLs plus two never-needed failures.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('PictureRefresh', () => {
    it('retry_only_missing_pictures_then_reopen_all_cached_without_requests_or_warning', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      // Cold-boot encrypted storage needs the completed unlock transition.
      await driver.delayMs(5000);
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const capture = async (name: string): Promise<void> => {
        expect(await driver.findComponent(ON.id('picture-refresh-fixture')) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();
        const web = await driver.waitForComponent(ON.id('html-mail'), 5000);
        await delegator.print(`PICTURE_REFRESH_BOUNDS: ${JSON.stringify({ name: name, bounds: await web.getBounds() })}\n`);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/picture-refresh-${name}.png`)).exitCode).assertEqual(0);
      };
      const requests = async (total: number, counts: string): Promise<void> => {
        for (let attempt = 0; attempt < 40 && ability.pictureRefreshRequestCount() < total; attempt++) {
          await driver.delayMs(100);
        }
        expect(ability.pictureRefreshRequestCount()).assertEqual(total);
        expect(ability.pictureRefreshRequestCounts()).assertEqual(counts);
        expect(ability.pictureRefreshNonContentRequests()).assertEqual(0);
      };
      const cached = async (count: number): Promise<void> => {
        for (let attempt = 0; attempt < 40 && !await ability.pictureRefreshCacheIntact(count); attempt++) {
          await driver.delayMs(100);
        }
        expect(await ability.pictureRefreshCacheIntact(count)).assertTrue();
      };
      const settled = async (): Promise<void> => {
        for (let attempt = 0; attempt < 40 && await driver.findComponent(ON.text('Loading pictures…')) !== null; attempt++) {
          await driver.delayMs(100);
        }
        expect(await driver.findComponent(ON.text('Loading pictures…')) === null).assertTrue();
      };
      const twoMissing = async (): Promise<void> => {
        await settled();
        expect(ability.pictureRefreshNonContentRequests()).assertEqual(0);
        const summary = await driver.waitForComponent(ON.id('picture-failure-summary'), 3000);
        const text = await summary.getText();
        await delegator.print(`PICTURE_REFRESH_STATUS: ${text}\n`);
        expect(text.startsWith('Pictures not saved (2): ')).assertTrue();
        expect(text.includes('Connection failed')).assertTrue();
        expect(text.includes('Server response 503')).assertTrue();
        const retry = await driver.waitForComponent(ON.id('refresh-pictures'), 3000);
        expect(await retry.getText()).assertEqual('Retry pictures');
        expect(await retry.isEnabled()).assertTrue();
      };
      const allSaved = async (): Promise<void> => {
        await cached(3); await settled();
        expect(ability.pictureRefreshNonContentRequests()).assertEqual(0);
        expect(await driver.findComponent(ON.id('picture-failure-summary')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('refresh-pictures')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();
      };
      try {
        await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await ability.showPictureRefreshFixture();
        expect(await driver.waitForComponent(ON.text('Synthetic saved pictures'), 10000) !== null).assertTrue();
        await requests(3, '1,1,1'); await cached(1); await twoMissing();
        await driver.delayMs(500); await capture('partial');
        ability.holdPictureRefreshFailures();
        await (await driver.waitForComponent(ON.id('refresh-pictures'), 3000)).click();
        await requests(5, '1,2,2');
        expect(await driver.waitForComponent(ON.text('Loading pictures…'), 3000) !== null).assertTrue();
        await (await driver.waitForComponent(ON.id('refresh-pictures'), 3000)).click();
        await driver.delayMs(700);
        await requests(5, '1,2,2'); await cached(1); await capture('held');
        ability.releasePictureRefresh();
        await twoMissing(); await cached(1);
        await driver.delayMs(500); await capture('failed-retry');
        ability.recoverPictureRefreshMissing();
        await (await driver.waitForComponent(ON.id('refresh-pictures'), 3000)).click();
        await requests(7, '1,3,3'); await allSaved();
        await driver.delayMs(700); await capture('recovered');
        // HTTP503 sentinel keeps every accidental request observable while all
        // resources are unavailable. Remounting destroys the old Web instance.
        await ability.reopenPictureRefreshUnavailable();
        expect(await driver.waitForComponent(ON.text('Synthetic saved pictures'), 5000) !== null).assertTrue();
        await driver.delayMs(1000); await allSaved();
        await requests(7, '1,3,3'); await capture('reopened');
        await delegator.print('PICTURE_REFRESH_RESULT: three generic-MIME PNGs persist as image/png; two missing pictures expose Retry pictures; held retries coalesce and never refetch the good picture; recovery hides retry and warning; a fresh renderer with every HTTP resource unavailable uses identical cached bytes and timestamps with zero new requests\n');
      } catch (error) {
        await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/picture-refresh-failure.png');
        throw error as Error;
      } finally {
        await delegator.print(`PICTURE_REFRESH_REQUESTS: ${ability.pictureRefreshRequestCounts()}\n`);
        await delegator.print(`PICTURE_REFRESH_NON_CONTENT_REQUESTS: ${ability.pictureRefreshNonContentRequests()}\n`);
        await delegator.print(`PICTURE_REFRESH_TRACE: ${ability.pictureRefreshTrace()}\n`);
        await ability.closePictureRefreshFixture();
        application.setColorMode(previousMode);
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
