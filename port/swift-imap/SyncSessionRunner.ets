// Same isolated trust-root setup as NetworkTestRunner, with no system CA change.
import { abilityDelegatorRegistry, TestRunner } from '@kit.TestKit';
import { Hypium } from '@ohos/hypium';
import { fileIo as fs } from '@kit.CoreFileKit';
export default class SyncSessionRunner implements TestRunner {
  onPrepare(): void {}
  async onRun(): Promise<void> {
    const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext();
    const folder = `${context.filesDir}/native-network-ca`;
    if (!fs.accessSync(folder)) { fs.mkdirSync(folder, true); }
    const ca = await context.createModuleContext('entry').resourceManager.getRawFileContent('root.crt');
    const file = fs.openSync(`${folder}/root.crt`, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.writeSync(file.fd, ca.buffer); } finally { fs.closeSync(file); }
    const tests = await import('../test/SyncSession.test');
    Hypium.hypiumTest(abilityDelegatorRegistry.getAbilityDelegator(), abilityDelegatorRegistry.getArguments(), tests.default);
  }
}
