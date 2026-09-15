// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';

export default class NativeCoreTestRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const native = await import('../test/NativeCore.test');
    const mime = await import('../test/Mime.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(),
      abilityDelegatorRegistry.getArguments(), () => { native.default(); mime.default(); });
  }
}
