// No mail services, external servers, or test module UI.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class HtmlImageSizingRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const tests = await import('../test/HtmlImageSizing.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
