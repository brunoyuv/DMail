import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class ReaderRecoveryRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    await abilityDelegatorRegistry.getAbilityDelegator().print('READER_RECOVERY_STAGE: runner started\n');
    const tests = await import('../test/ReaderRecovery.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
