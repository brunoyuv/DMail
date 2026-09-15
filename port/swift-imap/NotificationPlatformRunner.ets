// Socket-free OS gate; no certificate fixture or mail server setup is needed.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class NotificationPlatformRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    await abilityDelegatorRegistry.getAbilityDelegator().print('NOTIFICATION_PLATFORM_STAGE: runner setup started\n');
    const tests = await import('../test/NotificationPlatform.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
