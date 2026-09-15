// The two navigation cases reuse one live window. Harmony's ability monitor may
// report the terminated instance while a same-name ability is being restarted.
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver } from '@ohos.UiTest';
import { display } from '@kit.ArkUI';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
export class NavigationTestSession {
  private static ability: IMAPTestAbility | null = null;
  private static monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
  static async acquire(): Promise<IMAPTestAbility> {
    if (NavigationTestSession.ability) { return NavigationTestSession.ability; }
    // Standalone cover runs need the same bounded unlock/credential warmup as
    // the full suite. Reusing the live window skips this setup on case two.
    const driver = Driver.create(); await driver.wakeUpDisplay();
    const screen = display.getDefaultDisplaySync();
    await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
      Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
    await driver.delayMs(5000);
    const delegator = abilityDelegatorRegistry.getAbilityDelegator();
    await delegator.addAbilityMonitor(NavigationTestSession.monitor);
    await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
    NavigationTestSession.ability = await delegator.waitAbilityMonitor(NavigationTestSession.monitor, 5000) as IMAPTestAbility;
    return NavigationTestSession.ability;
  }
  static async release(): Promise<void> {
    const ability = NavigationTestSession.ability;
    NavigationTestSession.ability = null;
    if (ability) { await ability.context.terminateSelf(); }
    await abilityDelegatorRegistry.getAbilityDelegator().removeAbilityMonitor(NavigationTestSession.monitor);
  }
}
