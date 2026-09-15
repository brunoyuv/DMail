// Socket-free isolated test runner for persisted badge totals.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class UnreadBadgeRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    await abilityDelegatorRegistry.getAbilityDelegator().print('UNREAD_BADGE_STAGE: runner setup started\n');
    const tests = await import('../test/UnreadBadge.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
