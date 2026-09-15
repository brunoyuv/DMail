// Isolated synthetic transport gate, no mail protocol services.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class PictureTransportRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const tests = await import('../test/PictureTransport.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
