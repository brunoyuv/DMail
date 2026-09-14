// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { JmapAccount, JmapEmail, JmapMailbox } from '../../../main/ets/mail/jmap/JmapClient';
import { cacheReadyForReading, MAIL_RETENTION_MS } from '../../../main/ets/data/MailCacheModel';
import { mailOperationsAssertions, appendSentAssertions } from '../support/MailOperationsAssertions';
import { OutgoingDraft } from '../../../main/ets/mail/smtp/NativeSmtpClient';

const FIRST: JmapAccount = { id: 'first', name: 'A synthetic account', isPersonal: true, isReadOnly: false };
const SECOND: JmapAccount = { id: 'second', name: 'B synthetic account', isPersonal: true, isReadOnly: false };
const SESSION = 'https://fixture.example/session';
const INBOX: JmapMailbox = { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
  totalEmails: 1, unreadEmails: 1, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true };
const MAIL: JmapEmail = { id: 'shared-mail-id', threadId: 'shared-thread-id', messageIds: [], mailboxIds: ['inbox'], keywords: [],
  from: [], to: [], replyTo: [], subject: 'Alpha cached subject', preview: 'Saved preview', receivedAt: 100,
  hasAttachment: true, attachments: [{ id: '2', name: 'synthetic.txt', contentType: 'text/plain', size: 16, sizeIsEncoded: false }],
  textBody: 'Alpha downloaded body 中文 📬', htmlBody: '<p>Alpha downloaded body 中文 📬</p>',
  bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: true };

function context(): common.Context {
  return abilityDelegatorRegistry.getAbilityDelegator().getAppContext().getApplicationContext().createModuleContext('entry');
}

async function fresh(name: string): Promise<AccountStore> {
  const store = new AccountStore(name);
  await store.open(context());
  for (const account of await store.list()) { await store.remove(account.id); }
  return store;
}

async function cleanup(store: AccountStore): Promise<void> {
  await store.open(context());
  try { for (const account of await store.list()) { await store.remove(account.id); } }
  finally { await store.close(); }
}

export default function lastAccountTests(): void {
  describe('LastVisitedAccount', () => {
    it('dirty_saved_bodies_and_pagination_survive_reopen_without_crossing_accounts_or_renewing_downloads', 0, async () => {
      const name = 'thunderbird_saved_account_cache_test.db';
      let store = await fresh(name);
      try {
        const first = await store.add(SESSION, FIRST, 'cached-first-token');
        const second = await store.add(SESSION, SECOND, 'cached-second-token');
        const other = JSON.parse(JSON.stringify(MAIL)) as JmapEmail;
        other.subject = 'Beta cached subject'; other.textBody = 'Beta downloaded body';
        await store.mail.saveBoxes(first.id, [INBOX], false);
        await store.mail.saveBoxes(second.id, [INBOX], true);
        await store.mail.saveView(first.id, 'inbox', [MAIL], 40, 'alpha-query-state');
        await store.mail.saveView(second.id, 'inbox', [other], null, 'beta-query-state');
        await store.mail.saveEmail(first.id, MAIL); await store.mail.saveEmail(second.id, other);
        const before = (await store.mail.email(first.id, MAIL.id))!;
        await store.mail.markDirty(first.id, MAIL.id);
        expect(await store.mail.email(first.id, MAIL.id) === null).assertTrue();
        expect((await store.mail.view(first.id, 'inbox'))?.emails.length).assertEqual(0);
        await store.close(); store = new AccountStore(name); await store.open(context());
        const cached = (await store.mail.email(first.id, MAIL.id, true))!;
        expect(cached.stateDirty).assertTrue();
        expect(cached.mail.textBody).assertEqual(MAIL.textBody);
        expect(cached.mail.htmlBody).assertEqual(MAIL.htmlBody);
        expect(cacheReadyForReading(cached)).assertTrue();
        expect(cached.bodySavedAt).assertEqual(before.bodySavedAt);
        expect(await store.mail.email(first.id, MAIL.id) === null).assertTrue();
        const view = (await store.mail.view(first.id, 'inbox', true))!;
        expect(view.stateDirty).assertTrue(); expect(view.emails[0].subject).assertEqual(MAIL.subject);
        expect(view.nextPosition).assertEqual(40); expect(view.queryState).assertEqual('alpha-query-state');
        expect((await store.mail.boxes(first.id))?.readOnly).assertFalse();
        expect((await store.mail.boxes(second.id))?.readOnly).assertTrue();
        const isolated = (await store.mail.email(second.id, MAIL.id, true))!;
        expect(isolated.stateDirty).assertFalse(); expect(isolated.mail.textBody).assertEqual(other.textBody);
        expect((await store.mail.view(second.id, 'inbox', true))?.nextPosition).assertNull();
        expect((await store.mail.view(second.id, 'inbox', true))?.queryState).assertEqual('beta-query-state');
        const alphaIndex = await store.mail.cachedMessages(first.id);
        expect(alphaIndex.length).assertEqual(1);
        expect(alphaIndex[0].stateDirty).assertTrue(); expect(alphaIndex[0].summaryOnly).assertFalse();
        expect(alphaIndex[0].mail.textBody).assertEqual(MAIL.textBody);
        const betaIndex = await store.mail.cachedMessages(second.id);
        expect(betaIndex.length).assertEqual(1);
        expect(betaIndex[0].stateDirty).assertFalse(); expect(betaIndex[0].summaryOnly).assertFalse();
        expect(betaIndex[0].mail.textBody).assertEqual(other.textBody);
        expect((await store.mail.cachedMessages('missing-synthetic-account')).length).assertEqual(0);

        // A verified flag acknowledgement updates mutable metadata only.
        await store.mail.updateKeyword(first.id, MAIL.id, '$seen', true);
        const confirmed = (await store.mail.email(first.id, MAIL.id))!;
        expect(confirmed.stateDirty).assertFalse(); expect(confirmed.mail.keywords.includes('$seen')).assertTrue();
        expect(confirmed.savedAt).assertEqual(before.savedAt); expect(confirmed.bodySavedAt).assertEqual(before.bodySavedAt);
        expect(confirmed.bodyDecoderRevision).assertEqual(before.bodyDecoderRevision);
        expect(confirmed.mail.htmlBody).assertEqual(MAIL.htmlBody);
        expect(confirmed.mail.attachments![0].name).assertEqual('synthetic.txt');
        expect((await store.mail.view(first.id, 'inbox'))?.stateDirty).assertFalse();
        expect((await store.mail.email(second.id, MAIL.id))?.mail.keywords.includes('$seen')).assertFalse();
        const summary = JSON.parse(JSON.stringify(MAIL)) as JmapEmail;
        summary.id = 'never-downloaded'; summary.textBody = null; summary.htmlBody = null;
        await store.mail.saveView(first.id, 'inbox', [MAIL, summary], 40, 'alpha-query-state');
        await store.mail.markDirty(first.id, summary.id);
        const indexedSummary = (await store.mail.cachedMessages(first.id)).find(record => record.mail.id === summary.id)!;
        expect(indexedSummary.stateDirty).assertTrue(); expect(indexedSummary.summaryOnly).assertTrue();
        expect(indexedSummary.mail.textBody).assertNull(); expect(indexedSummary.bodySavedAt).assertNull();

        await store.mail.updateKeyword(first.id, summary.id, '$flagged', true);
        expect(await store.mail.email(first.id, summary.id, true) === null).assertTrue();
        expect((await store.mail.view(first.id, 'inbox'))?.emails[1].keywords.includes('$flagged')).assertTrue();
        // Conversation lookup obeys summary freshness and strips an expired body
        // independently, including its attachment metadata, without discarding headers.
        const aged = JSON.parse(JSON.stringify(MAIL)) as JmapEmail;
        aged.id = 'expired-conversation-record'; await store.mail.saveEmail(first.id, aged);
        const expired = (await store.mail.email(first.id, aged.id))!;
        expired.savedAt = Date.now() - MAIL_RETENTION_MS - 1000;
        const bodyAged = JSON.parse(JSON.stringify(MAIL)) as JmapEmail;
        bodyAged.id = 'expired-body-fresh-summary'; await store.mail.saveEmail(first.id, bodyAged);
        const bodyExpired = (await store.mail.email(first.id, bodyAged.id))!;
        bodyExpired.bodySavedAt = expired.savedAt;
        const db = await relationalStore.getRdbStore(context(), { name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true });
        try {
          await db.executeSql("UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email' AND cache_key = ?",
            [JSON.stringify(expired), first.id, aged.id]);
          await db.executeSql("UPDATE mail_cache SET payload = ? WHERE account_id = ? AND kind = 'email' AND cache_key = ?",
            [JSON.stringify(bodyExpired), first.id, bodyAged.id]);
        } finally { db.close(); }
        const freshIndex = await store.mail.cachedMessages(first.id);
        expect(freshIndex.some(record => record.mail.id === aged.id)).assertFalse();
        const retainedSummary = freshIndex.find(record => record.mail.id === bodyAged.id)!;
        expect(retainedSummary.summaryOnly).assertTrue(); expect(retainedSummary.bodySavedAt).assertNull();
        expect(retainedSummary.mail.subject).assertEqual(MAIL.subject);
        expect(retainedSummary.mail.textBody).assertNull(); expect(retainedSummary.mail.htmlBody).assertNull();
        expect(retainedSummary.mail.attachments === undefined).assertTrue();
        await appendSentAssertions(store, first.id, context());
        await mailOperationsAssertions(store, first.id, second.id, FIRST.id);
        const sending = new OutgoingDraft(); sending.id = 'synthetic-pending-send'; sending.state = 'sending';
        sending.to = 'recipient@example.test'; sending.subject = 'Synthetic pending send'; sending.text = 'Synthetic body';
        await store.saveOutgoing(first.id, sending);
        expect((await store.outgoing(first.id, true))?.state).assertEqual('sending');
        expect((await store.outgoing(first.id))?.state).assertEqual('unconfirmed');
        await store.mail.markDirty(first.id, MAIL.id);
        await store.remove(first.id);
        await store.saveOutgoing(first.id, sending);
        expect(await store.outgoing(first.id) === null).assertTrue();
        expect(await store.mail.email(first.id, MAIL.id, true) === null).assertTrue();
        expect(await store.mail.view(first.id, 'inbox', true) === null).assertTrue();
        expect((await store.mail.email(second.id, MAIL.id))?.mail.textBody).assertEqual(other.textBody);
        expect((await store.mail.cachedMessages(first.id)).length).assertEqual(0);
        expect((await store.mail.cachedMessages(second.id))[0].mail.textBody).assertEqual(other.textBody);
      } finally { await cleanup(store); }
    });

    it('version_five_upgrade_preserves_accounts_and_remembers_the_latest_visit_after_reopen', 0, async () => {
      const name = 'thunderbird_last_account_reopen_test.db';
      let store = await fresh(name);
      try {
        const first = await store.add(SESSION, FIRST, 'first-synthetic-token');
        const second = await store.add(SESSION, SECOND, 'second-synthetic-token');
        await store.close();
        const old = await relationalStore.getRdbStore(context(), {
          name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
        });
        try { await old.executeSql('DROP TABLE account_preferences'); old.version = 5; }
        finally { old.close(); }
        await store.open(context());
        expect(await store.lastVisitedAccount() === null).assertTrue();
        expect((await store.list())[0].id).assertEqual(first.id);
        expect(await store.credentials(second).authorization()).assertEqual('Bearer second-synthetic-token');
        // Rapid selections are persisted in call order on the shared write queue.
        const earlier = store.rememberVisitedAccount(first.id);
        const latest = store.rememberVisitedAccount(second.id);
        await earlier; await latest;
        expect((await store.lastVisitedAccount())?.id).assertEqual(second.id);
        await store.close();
        store = new AccountStore(name);
        await store.open(context());
        expect((await store.lastVisitedAccount())?.id).assertEqual(second.id);
        expect((await store.list()).length).assertEqual(2);
        // Removing another account leaves the visit intact; removing its target
        // clears it even when a late selection is queued after the removal.
        await store.remove(first.id);
        expect((await store.lastVisitedAccount())?.id).assertEqual(second.id);
        const removal = store.remove(second.id);
        const lateVisit = store.rememberVisitedAccount(second.id);
        await removal; await lateVisit;
        expect(await store.lastVisitedAccount() === null).assertTrue();
        await store.close(); await store.open(context());
        expect(await store.lastVisitedAccount() === null).assertTrue();
        expect((await store.list()).length).assertEqual(0);
      } finally { await cleanup(store); }
    });

    it('separate_encrypted_stores_do_not_share_a_selection', 0, async () => {
      const firstStore = await fresh('thunderbird_last_account_isolation_a_test.db');
      const secondStore = await fresh('thunderbird_last_account_isolation_b_test.db');
      try {
        const first = await firstStore.add(SESSION, FIRST, 'isolated-first-token');
        const second = await secondStore.add(SESSION, SECOND, 'isolated-second-token');
        await firstStore.rememberVisitedAccount(first.id);
        expect(await secondStore.lastVisitedAccount() === null).assertTrue();
        await secondStore.rememberVisitedAccount(second.id);
        await firstStore.rememberVisitedAccount(second.id);
        await firstStore.close(); await secondStore.close();
        await firstStore.open(context()); await secondStore.open(context());
        expect((await firstStore.lastVisitedAccount())?.id).assertEqual(first.id);
        expect((await secondStore.lastVisitedAccount())?.id).assertEqual(second.id);
        await firstStore.remove(first.id);
        expect((await secondStore.lastVisitedAccount())?.id).assertEqual(second.id);
      } finally { await cleanup(firstStore); await cleanup(secondStore); }
    });

    it('missing_pending_and_deleting_accounts_never_become_the_launch_target', 0, async () => {
      const name = 'thunderbird_last_account_stale_test.db';
      const store = await fresh(name);
      try {
        const first = await store.add(SESSION, FIRST, 'ready-first-token');
        const second = await store.add(SESSION, SECOND, 'ready-second-token');
        await store.rememberVisitedAccount(second.id);
        const db = await relationalStore.getRdbStore(context(), {
          name, securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
        });
        try {
          for (const status of ['pending', 'deleting']) {
            await db.executeSql('INSERT INTO accounts (id, server_id, name, session_url, status) VALUES (?, ?, ?, ?, ?)',
              [`synthetic-${status}`, status, status, SESSION, status]);
            await store.rememberVisitedAccount(`synthetic-${status}`);
            expect((await store.lastVisitedAccount())?.id).assertEqual(second.id);
          }
          await store.rememberVisitedAccount('missing-synthetic-id');
          expect((await store.lastVisitedAccount())?.id).assertEqual(second.id);
          await db.executeSql("UPDATE account_preferences SET account_id = 'missing-synthetic-id' WHERE name = 'last_visited'");
          expect(await store.lastVisitedAccount() === null).assertTrue();
          expect((await store.list())[0].id).assertEqual(first.id);
          await store.rememberVisitedAccount(second.id);
          await db.executeSql("UPDATE accounts SET status = 'deleting' WHERE id = ?", [second.id]);
          expect(await store.lastVisitedAccount() === null).assertTrue();
        } finally { db.close(); }
        // Startup recovery removes interrupted registrations/deletions without
        // changing the deterministic fallback or losing the remaining account.
        await store.close(); await store.open(context());
        expect(await store.lastVisitedAccount() === null).assertTrue();
        expect((await store.list()).length).assertEqual(1);
        expect((await store.list())[0].id).assertEqual(first.id);
        await store.rememberVisitedAccount(first.id);
        expect((await store.lastVisitedAccount())?.id).assertEqual(first.id);
      } finally { await cleanup(store); }
    });
  });
}
