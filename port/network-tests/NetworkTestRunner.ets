// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import { fileIo as fs } from '@kit.CoreFileKit';
export default class NetworkTestRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
    const folder = `${context.filesDir}/native-network-ca`;
    if (!fs.accessSync(folder)) { fs.mkdirSync(folder, true); }
    const ca = await context.createModuleContext('entry').resourceManager.getRawFileContent('root.crt');
    const file = fs.openSync(`${folder}/root.crt`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, ca.buffer); } finally { fs.closeSync(file); }
    const tests = await import('../test/Network.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
