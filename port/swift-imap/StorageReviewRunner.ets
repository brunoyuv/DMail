// Socket-free isolated runner for encrypted storage projection and lifetime.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class StorageReviewRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const tests = await import('../test/StorageReview.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
