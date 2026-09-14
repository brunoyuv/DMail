// No accounts, network requests, or production application access.
import { describe, it, expect } from '@ohos/hypium';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('HtmlTheme', () => {
    it('authored_html_quotes_and_original_pictures_follow_app_theme', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      const application = ability.context.getApplicationContext();
      const previousMode = ability.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      const capture = async (name: string): Promise<void> => {
        // Never capture unless our explicit synthetic fixture is in front.
        expect(await driver.findComponent(ON.id('html-theme-fixture')) !== null).assertTrue();
        const web = await driver.waitForComponent(ON.id('html-mail'), 5000);
        await delegator.print(`HTML_THEME_RESOURCES: {"name":"${name}","resources":${ability.themeResourceDiagnostics()}}\n`);
        expect(ability.themeBackground()).assertEqual(name.includes('dark') ? 0xFF191A1B : 0xFFFFFFFF);
        expect(ability.themeText()).assertEqual(name.includes('dark') ? 0xFFE5E7EB : 0xFF18191C);
        await delegator.print(`HTML_THEME_BOUNDS: ${JSON.stringify({ name: name, bounds: await web.getBounds() })}\n`);
        expect((await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/html-theme-${name}.png`)).exitCode).assertEqual(0);
      };
      try {
        await AppLanguage.set(ability.context, 'en');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await ability.showHtmlThemeFixture();
        expect(await driver.waitForComponent(ON.id('html-theme-fixture'), 10000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.text('Authored white panel'), 10000) !== null).assertTrue();
        await driver.delayMs(1200);
        await capture('reader-light');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
        await driver.delayMs(1500);
        await capture('reader-dark');
        await (await driver.waitForComponent(ON.text('Show quoted text'), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Older answer in green.'), 5000) !== null).assertTrue();
        await driver.delayMs(500); await capture('quotes-dark');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
        await driver.delayMs(1500);
        // Theme changes should restyle the mounted document, not reload and
        // refold its disclosure or reset the saved picture choice.
        expect(await driver.findComponent(ON.text('Hide quoted text')) !== null).assertTrue();
        expect(await driver.findComponent(ON.text('Older answer in green.')) !== null).assertTrue();
        await capture('quotes-light');
        await (await driver.waitForComponent(ON.id('html-theme-forward'), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Forward preview'), 5000) !== null).assertTrue();
        await driver.delayMs(1200); await capture('forward-light');
        application.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
        await driver.delayMs(1500);
        expect(await driver.findComponent(ON.text('Authored white panel')) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('load-pictures')) === null).assertTrue();
        await capture('forward-dark');
      } finally {
        application.setColorMode(previousMode);
        await ability.context.terminateSelf();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
