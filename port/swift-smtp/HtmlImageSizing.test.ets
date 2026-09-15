// The isolated main ability renders only generated failed images and an inline logo.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('HtmlImageSizing', () => {
    it('compares_failed_tiny_and_visible_images_with_authored_heights', 0, async () => {
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
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const capture = async (name: string): Promise<void> => {
        expect(await driver.findComponent(ON.id('html-image-sizing-fixture')) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('Synthetic newsletter')) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();
        const web = await driver.waitForComponent(ON.id('html-mail'), 5000);
        await delegator.print(`HTML_IMAGE_SIZING_BOUNDS: ${JSON.stringify({ name: name, web: await web.getBounds() })}\n`);
        // Web accessibility exposure of image IDs differs across ArkWeb builds.
        // Record exact image bounds when available; screenshots remain evidence.
        for (let index = 1; index <= 4; index++) {
          const image = await driver.findComponent(ON.id(`sizing-${index}`));
          if (image !== null) {
            await delegator.print(`HTML_IMAGE_SIZING_IMAGE: ${JSON.stringify({ name: name, image: index, bounds: await image.getBounds() })}\n`);
          }
        }
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/html-image-sizing-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await ability.showHtmlImageSizingFixture();
        expect(await driver.waitForComponent(ON.id('html-image-sizing-fixture'), 10000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.text('Synthetic newsletter'), 10000) !== null).assertTrue();
        await driver.delayMs(1400);
        await capture('current');
        await (await driver.findComponent(ON.id('html-image-sizing-compare'))).click();
        expect(await driver.waitForComponent(ON.text('Authored heights'), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.text('HTML: authored heights'), 5000) !== null).assertTrue();
        await driver.delayMs(1400);
        await capture('authored-height');
        await delegator.print('HTML_IMAGE_SIZING: four generated failures and valid inline logo captured in both height modes\n');
      } finally {
        application.setColorMode(previousMode);
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
