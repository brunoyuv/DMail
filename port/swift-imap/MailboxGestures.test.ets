import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, MatchPattern } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import IMAPTestAbility from '../abilities/IMAPTestAbility';

class GestureCredentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('gesture:fixture-password'))}`;
  }
}
export default function mailboxGestureTests(): void {
  describe('RealMailboxGestures', () => {
    it('saved_inbox_search_direction_and_native_pull_refresh', 0, async () => {
      const driver = Driver.create();
      await driver.wakeUpDisplay();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      const store = new AccountStore('imap_gestures_test.db'); await store.open(ability.context);
      try {
        for (const account of await store.list()) { await store.remove(account.id); }
        const credentials = new GestureCredentials();
        const session = await new NativeImapClient('imaps://localhost:9761', credentials).connect();
        await store.add('imaps://localhost:9761', session.accounts[0], (await credentials.authorization()).slice(6), 'reader@example.test');
        await ability.showMailboxFixture();
        expect(await driver.waitForComponent(ON.text('Message 92 refresh 1', MatchPattern.CONTAINS), 10000) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('account-server')) === null).assertTrue();
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        const unread = await driver.waitForComponent(ON.id('filter-unread'), 5000);
        expect(await unread.getText()).assertEqual(ability.context.resourceManager.getStringByNameSync('unread'));
        // A real pull gesture must fetch a changed server response, not just spin.
        let bounds = await (await driver.waitForComponent(ON.id('mail-list'), 5000)).getBounds();
        let x = Math.round((bounds.left + bounds.right) / 2);
        await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.15),
          x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.80), 700);
        expect(await driver.waitForComponent(ON.id('search-mail'), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.text('Message 92 refresh 2', MatchPattern.CONTAINS), 10000) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('connection-error')) === null).assertTrue();
        // Search stays hidden when direction reverses away from the list's top.
        bounds = await (await driver.waitForComponent(ON.id('mail-list'), 5000)).getBounds();
        x = Math.round((bounds.left + bounds.right) / 2);
        await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.80),
          x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.25), 800);
        await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.80),
          x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.25), 800);
        await driver.delayMs(500);
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.30),
          x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.50), 600);
        await driver.delayMs(350);
        expect(await driver.findComponent(ON.id('search-mail')) === null).assertTrue();
        for (let attempt = 0; attempt < 12; attempt++) {
          if (await driver.findComponent(ON.id('search-mail')) !== null) { break; }
          bounds = await (await driver.findComponent(ON.id('mail-list'))).getBounds();
          await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.15),
            x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.85), 700);
          await driver.delayMs(300);
        }
        expect(await driver.waitForComponent(ON.id('search-mail'), 5000) !== null).assertTrue();
        expect(await driver.waitForIdle(500, 5000)).assertTrue();
        const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-mailbox-gestures.png');
        expect(capture.exitCode).assertEqual(0);
      } finally {
        await ability.context.terminateSelf();
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
        await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
