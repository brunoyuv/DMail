import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class ReviewInboxRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    await abilityDelegatorRegistry.getAbilityDelegator().print('REVIEW_INBOX_STAGE: runner started\n');
    const tests = await import('../test/ReviewInbox.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
