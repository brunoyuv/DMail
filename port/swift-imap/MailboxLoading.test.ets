import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON, MatchPattern } from '@ohos.UiTest';
import { display } from '@kit.ArkUI';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import IMAPTestAbility from '../abilities/IMAPTestAbility';

class Credentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(`${this.mode}:fixture-password`))}`;
  }
}
function client(mode: string): NativeImapClient {
  return new NativeImapClient('imaps://localhost:9761', new Credentials(mode));
}
export default function tests(): void {
  describe('MailboxLoading', () => {
    it('folder_counts_request_only_needed_attributes', 0, async () => {
      const core = client('status-basic-only');
      const boxes = await core.mailboxes('default');
      expect(boxes.length).assertEqual(2);
      expect(boxes[0].countsKnown).assertTrue();
      expect(boxes[0].totalEmails).assertEqual(51);
      expect(boxes[0].unreadEmails).assertEqual(51);
      expect((await core.emailPage('default', boxes[0].id)).emails.length).assertEqual(50);
    });
    it('rejected_counts_do_not_prevent_listing_or_reading', 0, async () => {
      const core = client('status-fail');
      const boxes = await core.mailboxes('default');
      expect(boxes.length).assertEqual(2);
      expect(boxes.every(box => box.countsKnown === false)).assertTrue();
      const page = await core.emailPage('default', boxes[0].id);
      expect(page.emails.length).assertEqual(50);
      expect((await core.readEmail('default', page.emails[0].id))?.textBody).assertEqual('Hello from Thunderbird IMAP. 日本語 ✓');
    });
    it('dropped_count_connection_preserves_folders_and_next_page_reconnects', 0, async () => {
      const core = client('status-drop');
      const boxes = await core.mailboxes('default');
      expect(boxes.length).assertEqual(2);
      expect(boxes.every(box => box.countsKnown === false)).assertTrue();
      expect((await core.emailPage('default', boxes[0].id)).emails.length).assertEqual(50);
    });
    it('empty_inbox_failure_has_no_load_more_and_pull_refresh_recovers', 0, async () => {
      const driver = Driver.create();
      await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(3000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      const store = new AccountStore('imap_gestures_test.db'); await store.open(ability.context);
      try {
        for (const account of await store.list()) { await store.remove(account.id); }
        const credentials = new Credentials('list-retry');
        const session = await client('list-retry').connect();
        await store.add('imaps://localhost:9761', session.accounts[0], (await credentials.authorization()).slice(6), 'reader@example.test');
        await ability.showMailboxFixture();
        expect(await driver.waitForComponent(ON.id('connection-error'), 10000) !== null).assertTrue();
        const more = ability.context.resourceManager.getStringByNameSync('load_more');
        expect(await driver.findComponent(ON.text(more)) === null).assertTrue();
        const bounds = await (await driver.waitForComponent(ON.id('mail-list'), 5000)).getBounds();
        const x = Math.round((bounds.left + bounds.right) / 2);
        await driver.swipe(x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.15),
          x, Math.round(bounds.top + (bounds.bottom-bounds.top)*0.80), 700);
        expect(await driver.waitForComponent(ON.text('Message 92', MatchPattern.CONTAINS), 10000) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('connection-error')) === null).assertTrue();
        expect((await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/mailbox-loading-recovered.png')).exitCode).assertEqual(0);
      } finally {
        await ability.context.terminateSelf();
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close(); await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
