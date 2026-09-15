import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
export default class ComposeAttachmentsRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    await abilityDelegatorRegistry.getAbilityDelegator().print('ATTACHMENTS_STAGE: runner started\n');
    const tests = await import('../test/ComposeAttachments.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
