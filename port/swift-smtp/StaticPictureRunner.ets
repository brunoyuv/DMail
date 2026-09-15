// Isolated synthetic main-HAP UI only; no real mail or external services.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class StaticPictureRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const tests = await import('../test/StaticPicture.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
