import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { relationalStore } from '@kit.ArkData';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import IMAPTestAbility from '../abilities/IMAPTestAbility';

class Credentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(`${this.mode}:fixture-password`))}`;
  }
}
function client(mode = 'account', port = 9761): NativeImapClient {
  return new NativeImapClient(`imaps://localhost:${port}`, new Credentials(mode));
}
function id(uid: number, validity = 77): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(
    JSON.stringify({ mailbox: 'INBOX', uid, validity }))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function rejects(operation: () => Promise<Object | null>, code?: string): Promise<void> {
  let failure: JmapError | null = null;
  try { await operation(); } catch (error) { failure = error as JmapError; }
  expect(failure !== null).assertTrue();
  if (code !== undefined) { expect(failure?.code).assertEqual(code); }
}
export default function accountTests(): void {
  describe('ProductionIMAPAccount', () => {
    it('production_read_page_and_mime', 0, async () => {
      const core = client();
      const session = await core.connect();
      expect(session.accounts[0].name).assertEqual('account');
      expect(session.accounts[0].isReadOnly).assertFalse();
      const boxes = await core.mailboxes('default');
      expect(boxes.length).assertEqual(2);
      const inbox = boxes.find(box => box.role === 'inbox')!;
      expect(inbox.totalEmails).assertEqual(51); expect(inbox.unreadEmails).assertEqual(51);
      const page = await core.emailPage('default', inbox.id);
      expect(page.emails.length).assertEqual(50); expect(page.nextPosition).assertEqual(50);
      expect(page.emails[0].id).assertEqual(id(92)); expect(page.emails[49].id).assertEqual(id(43));
      expect(page.emails[0].subject).assertEqual('Message 92'); expect(page.emails[0].textBody).assertNull();
      const second = await core.emailPage('default', inbox.id, 50, page.queryState);
      expect(second.emails.length).assertEqual(1); expect(second.emails[0].id).assertEqual(id(42));
      expect(second.nextPosition).assertNull();
      const mail = await core.readEmail('default', id(42));
      expect(mail?.textBody).assertEqual('Hello from Thunderbird IMAP. 日本語 ✓');
      expect(mail?.keywords.length).assertEqual(0);
      expect(mail?.bodyEncodingProblem).assertFalse();
      expect(mail?.receivedAt).assertEqual(1789293600000);
    });
    it('production_missing_selection_uidnext_uses_explicit_status', 0, async () => {
      const core = client('no-next', 9765);
      const inbox = (await core.mailboxes('default'))[0];
      const page = await core.emailPage('default', inbox.id);
      expect(page.emails.length).assertEqual(50);
      expect(page.emails[0].id).assertEqual(id(92));
      const second = await core.emailPage('default', inbox.id, 50, page.queryState);
      expect(second.emails[0].id).assertEqual(id(42));
      expect((await core.readEmail('default', id(42)))?.textBody).assertEqual('Hello from Thunderbird IMAP. 日本語 ✓');
    });
    it('production_uidnext_fallback_rejects_changed_or_incomplete_status', 0, async () => {
      const inbox = (await client().mailboxes('default'))[0];
      for (const mode of ['next-changed', 'next-count']) {
        await rejects(() => client(mode).emailPage('default', inbox.id), 'queryChanged');
        await rejects(() => client(mode).readEmail('default', id(42)), 'queryChanged');
      }
      await rejects(() => client('next-missing').emailPage('default', inbox.id), 'invalidResponse');
    });
    it('production_list_without_extensions', 0, async () => {
      const boxes = await client('account', 9765).mailboxes('default');
      expect(boxes.length).assertEqual(2); expect(boxes[0].totalEmails).assertEqual(51);
    });
    it('production_rejects_stale_and_changing_mailbox', 0, async () => {
      await rejects(() => client('epoch').readEmail('default', id(42)), 'queryChanged');
      const inbox = (await client().mailboxes('default'))[0];
      await rejects(() => client('changed').emailPage('default', inbox.id), 'queryChanged');
      await rejects(() => client().emailPage('default', inbox.id, 50, 'stale'), 'queryChanged');
    });
    it('production_missing_and_mismatched_uid', 0, async () => {
      expect(await client('missing').readEmail('default', id(42))).assertNull();
      await rejects(() => client('wronguid').readEmail('default', id(42)), 'invalidResponse');
    });
    it('production_auth_tls_and_pin_failures', 0, async () => {
      await rejects(() => client('bad').connect(), 'authenticationRequired');
      for (const port of [9762, 9763, 9764]) { await rejects(() => client('account', port).connect()); }
      await rejects(() => new NativeImapClient('http://localhost:9761', new Credentials('account')).connect(), 'unsafeEndpoint');
    });
    it('production_changes_only_requested_flags', 0, async () => {
      const core = client('writer');
      for (const enabled of [true, false]) {
        for (const keyword of ['$seen', '$flagged']) {
          await core.setKeyword('default', id(42), keyword as '$seen' | '$flagged', enabled);
          const mail = await core.readEmail('default', id(42));
          expect(mail?.keywords.includes(keyword)).assertEqual(enabled);
          if (keyword === '$seen') { expect((await core.mailboxes('default'))[0].unreadEmails).assertEqual(enabled ? 50 : 51); }
        }
      }
    });
    it('production_respects_mailbox_permissions', 0, async () => {
      for (const mode of ['readonly', 'limited', 'noflags', 'wildcard', 'omitted']) {
        const core = client(mode); const mail = await core.readEmail('default', id(42));
        expect(mail?.maySetSeen).assertEqual(mode === 'limited' || mode === 'omitted');
        expect(mail?.maySetKeywords).assertEqual(mode === 'omitted');
        if (mode === 'limited' || mode === 'omitted') { await core.setKeyword('default', id(42), '$seen', true); }
        if (mode !== 'omitted') { await rejects(() => core.setKeyword('default', id(42), '$flagged', true), mode === 'readonly' ? 'accountReadOnly' : 'forbidden'); }
      }
    });
    it('production_write_rejects_stale_or_missing_uid', 0, async () => {
      await rejects(() => client('epoch').setKeyword('default', id(42), '$seen', true), 'queryChanged');
      await rejects(() => client('missing').setKeyword('default', id(42), '$seen', true), 'messageNotFound');
      await rejects(() => client('wronguid').setKeyword('default', id(42), '$seen', true), 'invalidResponse');
    });
    it('production_rejected_store_is_not_success', 0, async () => {
      await rejects(() => client('storefail').setKeyword('default', id(42), '$seen', true), 'changeUnconfirmed');
      expect((await client('storefail').readEmail('default', id(42)))?.keywords.includes('$seen')).assertFalse();
    });
    it('production_lost_store_reply_is_not_replayed', 0, async () => {
      await rejects(() => client('lost').setKeyword('default', id(42), '$flagged', true), 'changeUnconfirmed');
      expect((await client('lost').readEmail('default', id(42)))?.keywords.includes('$flagged')).assertTrue();
    });
    it('production_ignored_store_is_not_success', 0, async () => {
      await rejects(() => client('ignored').setKeyword('default', id(42), '$seen', true), 'changeUnconfirmed');
    });
    it('production_email_identity_is_separate_from_login', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const store = new AccountStore('imap_identity_test.db'); await store.open(context);
      const server = (await client().connect()).accounts[0];
      const authorization = await new Credentials('account').authorization();
      const account = await store.add('imaps://localhost:9761', server, authorization.slice(6), 'reader@example.test');
      await store.close(); await store.open(context);
      try {
        const restored = (await store.list()).find(saved => saved.id === account.id)!;
        expect(restored.emailAddress).assertEqual('reader@example.test');
        expect(restored.name).assertEqual('reader@example.test');
        expect(await store.credentials(restored).authorization()).assertEqual(authorization);
        await rejects(() => store.add('imaps://localhost:9761', server, authorization.slice(6), 'not-an-email'));
        expect((await store.list()).length).assertEqual(1);
      } finally { await store.remove(account.id); await store.close(); }
    });
    it('production_version_two_migration_preserves_login_without_inventing_email', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const name = 'imap_v2_migration_test.db'; const store = new AccountStore(name); await store.open(context);
      const server = (await client().connect()).accounts[0];
      const authorization = await new Credentials('account').authorization();
      const account = await store.add('imaps://localhost:9761', server, authorization.slice(6));
      await store.close();
      const db = await relationalStore.getRdbStore(context, { name, encrypt: true, securityLevel: relationalStore.SecurityLevel.S3 });
      try {
        await db.executeSql('CREATE TABLE accounts_v2 (id TEXT PRIMARY KEY, server_id TEXT NOT NULL, name TEXT NOT NULL, session_url TEXT NOT NULL, status TEXT NOT NULL)');
        await db.executeSql('INSERT INTO accounts_v2 SELECT id, server_id, name, session_url, status FROM accounts');
        await db.executeSql('DROP TABLE accounts'); await db.executeSql('ALTER TABLE accounts_v2 RENAME TO accounts');
        db.version = 2;
      } finally { db.close(); }
      await store.open(context);
      try {
        const restored = (await store.list()).find(saved => saved.id === account.id)!;
        expect(restored.emailAddress).assertEqual(''); expect(restored.name).assertEqual('account');
        expect(await store.credentials(restored).authorization()).assertEqual(authorization);
      } finally { await store.remove(account.id); await store.close(); }
    });
    it('production_account_ui_and_saved_credentials', 0, async () => {
      const driver = Driver.create();
      await driver.wakeUpDisplay();
      if (await driver.findComponent(ON.id('ScreenLockRootComponent')) !== null) {
        const size = await driver.getDisplaySize();
        await driver.swipe(Math.round(size.x/2), Math.round(size.y*0.8), Math.round(size.x/2), Math.round(size.y*0.25), 2000);
      }
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'IMAPTestAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry_test', abilityName: 'IMAPTestAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as IMAPTestAbility;
      await ability.showFixture(true);
      const store = new AccountStore('imap_ui_test.db'); await store.open(ability.context);
      try {
        const connect = await driver.waitForComponent(ON.id('connect-account').enabled(true), 5000);
        await connect.click();
        await driver.waitForComponent(ON.id('account-token').text(''), 5000);
        const saved = await store.list(); expect(saved.length).assertEqual(1);
        expect(saved[0].sessionUrl).assertEqual('imaps://localhost:9761');
        expect(saved[0].emailAddress).assertEqual('reader@example.test');
        expect(saved[0].name).assertEqual('reader@example.test');
        expect(await store.credentials(saved[0]).authorization()).assertEqual(await new Credentials('account').authorization());
        // Recreate the screen, then read using credentials restored from Asset Store.
        await ability.showFixture(false);
        await (await driver.waitForComponent(ON.id(`account-${saved[0].id}`).enabled(true), 5000)).click();
        const inboxId = 'IklOQk9YIg';
        await (await driver.waitForComponent(ON.id(`remote-box-${inboxId}`).enabled(true), 5000)).click();
        await (await driver.waitForComponent(ON.id(`remote-mail-${id(92)}`).enabled(true), 5000)).click();
        const body = await driver.waitForComponent(ON.text('Hello from Thunderbird IMAP. 日本語 ✓'), 5000);
        expect(await body.getText()).assertEqual('Hello from Thunderbird IMAP. 日本語 ✓');
        const star = ability.context.resourceManager.getStringByNameSync('star');
        const unstar = ability.context.resourceManager.getStringByNameSync('unstar');
        await (await driver.waitForComponent(ON.text(star).enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.text(unstar).enabled(true), 5000) !== null).assertTrue();
        await (await driver.waitForComponent(ON.text(unstar).enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.text(star).enabled(true), 5000) !== null).assertTrue();
        await driver.delayMs(2000);
        expect(await driver.waitForIdle(500, 5000)).assertTrue();
        const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-imap-reader.png');
        expect(capture.exitCode).assertEqual(0);
      } finally {
        for (const account of await store.list()) { await store.remove(account.id); }
        await store.close();
        await delegator.removeAbilityMonitor(monitor);
        await ability.context.terminateSelf();
      }
    });
  });
}
