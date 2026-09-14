// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { relationalStore } from '@kit.ArkData';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { JmapAccount, JmapError, JmapEmail, JmapMailbox } from '../../../main/ets/mail/jmap/JmapClient';
import { Driver, ON } from '@kit.TestKit';
import { FixtureTransport } from './Jmap.test';
import AccountTestAbility from '../testability/AccountTestAbility';

const DB_NAME = 'thunderbird_account_test.db';
const SERVER: JmapAccount = { id: 'personal', name: "Fixture's mailbox", isPersonal: true, isReadOnly: false };
const CACHED_MAIL: JmapEmail = { id: 'cached1', threadId: 'thread1', messageIds: [], mailboxIds: ['inbox'], keywords: [],
  from: [], to: [], replyTo: [], subject: 'Saved mail', preview: 'Preview', receivedAt: 100,
  hasAttachment: false, textBody: 'Native cached body 鸿蒙 📬', bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false };
const CACHED_BOX: JmapMailbox = { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
  totalEmails: 1, unreadEmails: 1, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true };

async function ready(driver: Driver): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await driver.findComponent(ON.id('connection-loading')) === null) { return; }
    await driver.delayMs(50);
  }
  throw new Error('Mail screen did not finish loading');
}

export default function accountTests(): void {
  describe('AccountNative', () => {
    it('encrypted_mail_cache_reopens_isolates_accounts_and_purges_on_disconnect', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const store = new AccountStore('thunderbird_cache_test.db');
      await store.open(context);
      const first = await store.add('https://fixture.example/session', SERVER, 'cache-first-token');
      const second = await store.add('https://fixture.example/session', SERVER, 'cache-second-token');
      try {
        await store.mail.saveBoxes(first.id, [CACHED_BOX]);
        await store.mail.saveView(first.id, 'inbox', [CACHED_MAIL]);
        expect(await store.mail.email(first.id, CACHED_MAIL.id) === null).assertTrue();
        await store.mail.saveEmail(first.id, CACHED_MAIL);
        const other = JSON.parse(JSON.stringify(CACHED_MAIL)) as JmapEmail;
        other.textBody = 'Other account body';
        await store.mail.saveEmail(second.id, other);
        await store.close(); await store.open(context);
        expect((await store.mail.boxes(first.id))?.boxes[0].name).assertEqual('Inbox');
        expect((await store.mail.email(first.id, CACHED_MAIL.id))?.mail.textBody).assertEqual(CACHED_MAIL.textBody);
        expect((await store.mail.email(second.id, CACHED_MAIL.id))?.mail.textBody).assertEqual('Other account body');
        const summary = JSON.parse(JSON.stringify(CACHED_MAIL)) as JmapEmail;
        summary.textBody = null; summary.keywords = ['$seen'];
        await store.mail.saveView(first.id, 'inbox', [summary]);
        expect((await store.mail.email(first.id, CACHED_MAIL.id))?.mail.textBody).assertEqual(CACHED_MAIL.textBody);
        await store.mail.markDirty(first.id, CACHED_MAIL.id);
        expect(await store.mail.email(first.id, CACHED_MAIL.id) === null).assertTrue();
        expect((await store.mail.view(first.id, 'inbox'))?.emails.length).assertEqual(0);
        const archived = JSON.parse(JSON.stringify(CACHED_MAIL)) as JmapEmail;
        archived.mailboxIds = ['archive'];
        await store.mail.saveEmail(first.id, archived);
        expect((await store.mail.view(first.id, 'inbox'))?.emails.length).assertEqual(0);
        await store.remove(first.id);
        await store.mail.saveEmail(first.id, CACHED_MAIL);
        expect(await store.mail.boxes(first.id) === null).assertTrue();
        expect(await store.mail.email(first.id, CACHED_MAIL.id) === null).assertTrue();
        const db = await relationalStore.getRdbStore(context, { name: 'thunderbird_cache_test.db', encrypt: true,
          securityLevel: relationalStore.SecurityLevel.S3 });
        const rows = await db.querySql('SELECT COUNT(*) FROM mail_cache WHERE account_id = ?', [first.id]);
        try { rows.goToFirstRow(); expect(rows.getLong(0)).assertEqual(0); } finally { rows.close(); db.close(); }
        expect((await store.mail.email(second.id, CACHED_MAIL.id))?.mail.textBody).assertEqual('Other account body');
      } finally { await store.remove(first.id); await store.remove(second.id); await store.close(); }
    });
    it('version_one_account_database_migrates_without_losing_account_or_token', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const name = 'thunderbird_cache_migration_test.db';
      const store = new AccountStore(name); await store.open(context);
      const account = await store.add('https://fixture.example/session', SERVER, 'migration-fixture-token');
      await store.close();
      const db = await relationalStore.getRdbStore(context, { name, encrypt: true, securityLevel: relationalStore.SecurityLevel.S3 });
      await db.executeSql('DROP TABLE mail_cache'); db.version = 1; db.close();
      await store.open(context);
      try {
        expect((await store.list()).some((saved) => saved.id === account.id)).assertTrue();
        expect(await store.credentials(account).authorization()).assertEqual('Bearer migration-fixture-token');
        await store.mail.saveEmail(account.id, CACHED_MAIL);
        expect((await store.mail.email(account.id, CACHED_MAIL.id))?.mail.textBody).assertEqual(CACHED_MAIL.textBody);
      } finally { await store.remove(account.id); await store.close(); }
    });
    it('native_account_setup_reads_changes_flags_and_recovers_lost_response', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      // Each bounded test session can begin at the emulator lock screen.
      const driver = Driver.create();
      await driver.wakeUpDisplay();
      if (await driver.findComponent(ON.id('ScreenLockRootComponent')) !== null) {
        const size = await driver.getDisplaySize();
        await driver.swipe(Math.round(size.x / 2), Math.round(size.y * 0.8),
          Math.round(size.x / 2), Math.round(size.y * 0.25), 2000);
      }
      let destroyed: () => void = () => {};
      const closed = new Promise<void>((resolve) => { destroyed = resolve; });
      let monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'AccountTestAbility', onAbilityDestroy: () => destroyed() };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.dev', abilityName: 'AccountTestAbility', moduleName: 'entry_test' });
      let testAbility = await delegator.waitAbilityMonitor(monitor, 5000) as AccountTestAbility;
      await testAbility.showFixture(true);
      const context = testAbility.context;
      const cleanup = new AccountStore('thunderbird_ui_test.db');
      await cleanup.open(context);
      try {
        const connect = await driver.waitForComponent(ON.id('connect-account').enabled(true), 5000);
        await connect.click();
        const token = await driver.waitForComponent(ON.id('account-token').text(''), 5000);
        expect(await token.getText()).assertEqual('');
        const account = await driver.waitForComponent(ON.text('Fixture'), 5000);
        await account.click();
        await (await driver.waitForComponent(ON.id('remote-box-inbox').enabled(true), 5000)).click();
        await (await driver.waitForComponent(ON.id('remote-mail-e1').enabled(true), 5000)).click();
        const body = await driver.waitForComponent(ON.text('Hello from the fixture. 鸿蒙 📬'), 5000);
        expect(await body.getText()).assertEqual('Hello from the fixture. 鸿蒙 📬');
        const read = context.resourceManager.getStringByNameSync('mark_read');
        const unread = context.resourceManager.getStringByNameSync('mark_unread');
        const star = context.resourceManager.getStringByNameSync('star');
        const unstar = context.resourceManager.getStringByNameSync('unstar');
        await ready(driver);
        await (await driver.waitForComponent(ON.text(read), 5000)).click();
        expect(await driver.waitForComponent(ON.text(unread), 5000) !== null).assertTrue();
        await ready(driver);
        await (await driver.waitForComponent(ON.text(star), 5000)).click();
        expect(await driver.waitForComponent(ON.text(unstar), 5000) !== null).assertTrue();
        await ready(driver);
        await (await driver.waitForComponent(ON.text(unread), 5000)).click();
        expect(await driver.waitForComponent(ON.text(read), 5000) !== null).assertTrue();
        await ready(driver);
        await (await driver.waitForComponent(ON.text(unstar), 5000)).click();
        expect(await driver.waitForComponent(ON.text(star), 5000) !== null).assertTrue();
        // Simulate a server applying a write but losing the acknowledgement.
        // The client must not silently replay it or optimistically claim success.
        await new FixtureTransport().send({ url: 'https://fixture.example/lose-next-write-response', method: 'POST',
          headers: { Authorization: 'Bearer fixture-only-token' }, maxResponseBytes: 4096 });
        await ready(driver);
        await (await driver.waitForComponent(ON.text(star), 5000)).click();
        const error = await driver.waitForComponent(ON.id('connection-error'), 5000);
        expect(await error.getText()).assertEqual(context.resourceManager.getStringByNameSync('change_unconfirmed'));
        await (await driver.waitForComponent(ON.id('refresh-message'), 5000)).click();
        expect(await driver.waitForComponent(ON.text(unstar), 5000) !== null).assertTrue();
        // Inspector-tree readiness precedes compositor animation completion.
        await driver.delayMs(2000);
        expect(await driver.waitForIdle(500, 5000)).assertTrue();
        const capture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-connected-fixture.png');
        if (capture.exitCode !== 0) { throw new Error('Screenshot failed: ' + capture.stdResult); }
        await ready(driver);
        await (await driver.waitForComponent(ON.text(context.resourceManager.getStringByNameSync('archive')), 5000)).click();
        const undo = await driver.waitForComponent(ON.id('undo-archive').enabled(true), 5000);
        expect(undo !== null).assertTrue();
        expect(await driver.findComponent(ON.id('remote-mail-e1')) === null).assertTrue();
        await driver.delayMs(1500);
        const archiveCapture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-archive-fixture.png');
        if (archiveCapture.exitCode !== 0) { throw new Error('Screenshot failed: ' + archiveCapture.stdResult); }
        await undo.click();
        expect(await driver.waitForComponent(ON.id('remote-star-e1'), 5000) !== null).assertTrue();
        await ready(driver);
        await driver.pressBack();
        expect(await driver.waitForComponent(ON.id('remote-box-inbox').enabled(true), 5000) !== null).assertTrue();
        expect(await driver.findComponent(ON.id('cache-warning')) === null).assertTrue();
        await new FixtureTransport().send({ url: 'https://fixture.example/offline', method: 'POST',
          headers: { Authorization: 'Bearer fixture-only-token' }, maxResponseBytes: 4096 });
        await cleanup.close();
        await testAbility.context.terminateSelf();
        await closed;
        await delegator.removeAbilityMonitor(monitor);
        monitor = { abilityName: 'AccountTestAbility' };
        await delegator.addAbilityMonitor(monitor);
        await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.dev', abilityName: 'AccountTestAbility',
          moduleName: 'entry_test' });
        testAbility = await delegator.waitAbilityMonitor(monitor, 5000) as AccountTestAbility;
        await testAbility.showFixture(false);
        await cleanup.open(testAbility.context);
        await ready(driver);
        await (await driver.waitForComponent(ON.text('Fixture'), 5000)).click();
        expect(await driver.waitForComponent(ON.id('saved-copy'), 5000) !== null).assertTrue();
        await (await driver.waitForComponent(ON.id('remote-box-inbox').enabled(true), 5000)).click();
        await (await driver.waitForComponent(ON.id('remote-mail-e1').enabled(true), 5000)).click();
        expect(await driver.waitForComponent(ON.text('Hello from the fixture. 鸿蒙 📬'), 5000) !== null).assertTrue();
        expect(await driver.waitForComponent(ON.id('saved-copy'), 5000) !== null).assertTrue();
        await driver.delayMs(1500);
        expect(await driver.waitForComponent(ON.type('BarItem').enabled(false), 5000) !== null).assertTrue();
        expect((await driver.findComponents(ON.type('BarItem').enabled(false))).length).assertEqual(3);
        expect(await driver.findComponent(ON.id('connection-error')) === null).assertTrue();
        const offlineCapture = await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-offline-fixture.png');
        if (offlineCapture.exitCode !== 0) { throw new Error('Screenshot failed: ' + offlineCapture.stdResult); }
        await new FixtureTransport().send({ url: 'https://fixture.example/online', method: 'POST',
          headers: { Authorization: 'Bearer fixture-only-token' }, maxResponseBytes: 4096 });
        await (await driver.waitForComponent(ON.id('__NavdestinationField__NavigationMenu__MenuItem1__'), 5000)).click();
        // A click returns before ArkUI publishes its loading state. Wait for
        // the observable completion, not the briefly absent loading spinner.
        for (const index of [1, 2, 3]) {
          expect(await driver.waitForComponent(ON.id(`__NavdestinationField__ToolBar__MenuItem${index}__`).enabled(true), 5000) !== null).assertTrue();
        }
        expect(await driver.findComponent(ON.id('saved-copy')) === null).assertTrue();
      } catch (error) {
        await delegator.executeShellCommand('rm -f /data/local/tmp/thunderbird-cache-debug.png');
        await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/thunderbird-cache-debug.png');
        await delegator.executeShellCommand('uitest dumpLayout -p /data/local/tmp/thunderbird-cache-debug.json');
        throw error as Error;
      } finally {
        try {
          await new FixtureTransport().send({ url: 'https://fixture.example/online', method: 'POST',
            headers: { Authorization: 'Bearer fixture-only-token' }, maxResponseBytes: 4096 });
          const saved = await cleanup.list();
          for (const account of saved) { await cleanup.remove(account.id); }
          expect((await cleanup.list()).length).assertEqual(0);
          for (const account of saved) {
            let code = '';
            try { await cleanup.credentials(account).authorization(); } catch (error) { code = (error as JmapError).code; }
            expect(code).assertEqual('authenticationRequired');
          }
        } finally {
          await cleanup.close();
          try { await testAbility.context.terminateSelf(); } catch (_) {}
          await delegator.removeAbilityMonitor(monitor);
        }
      }
    });
    it('saved_account_and_secure_token_survive_reopen_and_are_removed_together', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const store = new AccountStore(DB_NAME);
      await store.open(context);
      const account = await store.add('https://fixture.example/session', SERVER, 'fixture-only-token');
      await store.close();
      const reopened = new AccountStore(DB_NAME);
      await reopened.open(context);
      try {
        const accounts = await reopened.list();
        const saved = accounts.find((item) => item.id === account.id);
        expect(saved?.name).assertEqual("Fixture's mailbox");
        expect(await reopened.credentials(account).authorization()).assertEqual('Bearer fixture-only-token');
        expect(JSON.stringify(accounts).includes('fixture-only-token')).assertFalse();
        await reopened.remove(account.id);
        expect((await reopened.list()).some((item) => item.id === account.id)).assertFalse();
        let code = '';
        try { await reopened.credentials(account).authorization(); } catch (error) { code = (error as JmapError).code; }
        expect(code).assertEqual('authenticationRequired');
      } finally { await reopened.remove(account.id); await reopened.close(); }
    });
    it('interrupted_registration_is_recovered_without_orphaned_secret', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
      const store = new AccountStore(DB_NAME);
      await store.open(context);
      const account = await store.add('https://fixture.example/session', SERVER, 'fixture-recovery-token');
      await store.close();
      const db = await relationalStore.getRdbStore(context, {
        name: DB_NAME, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
      });
      await db.executeSql("UPDATE accounts SET status = 'pending' WHERE id = ?", [account.id]);
      db.close();
      const recovered = new AccountStore(DB_NAME);
      await recovered.open(context);
      try {
        expect((await recovered.list()).some((item) => item.id === account.id)).assertFalse();
        let code = '';
        try { await recovered.credentials(account).authorization(); } catch (error) { code = (error as JmapError).code; }
        expect(code).assertEqual('authenticationRequired');
      } finally { await recovered.remove(account.id); await recovered.close(); }
    });
    it('oversized_tokens_are_rejected_before_account_registration', 0, async () => {
      const store = new AccountStore(DB_NAME);
      await store.open(abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry'));
      try {
        const before = (await store.list()).length;
        let rejected = false;
        try { await store.add('https://fixture.example/session', SERVER, 'a'.repeat(1025)); }
        catch (_) { rejected = true; }
        expect(rejected).assertTrue();
        expect((await store.list()).length).assertEqual(before);
      } finally { await store.close(); }
    });
  });
}
