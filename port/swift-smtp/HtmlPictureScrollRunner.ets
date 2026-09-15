import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class HtmlPictureScrollRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const tests = await import('../test/HtmlPictureScroll.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
