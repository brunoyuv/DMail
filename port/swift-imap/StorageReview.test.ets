// Synthetic native RDB projection/lifetime gate. No mail or HTTP service runs.
import { describe, it, expect } from '@ohos/hypium';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver } from '@ohos.UiTest';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { cacheReadyForReading } from '../../../main/ets/data/MailCacheModel';
import { JmapEmail, shallowCopyEmail } from '../../../main/ets/mail/jmap/JmapClient';
import { navigationAccount } from '../support/NavigationClient';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';

export default function tests(): void {
  describe('StorageReview', () => {
    it('native_projection_retains_body_and_reopen_waits_for_close', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(5000);
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      await ability.hideNavigationFixture();
      const store = new AccountStore('storage_review_test.db');
      try {
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        ability.resetNavigationFixtureState();
        const account = await store.add('https://storage.example.test/session', navigationAccount('Storage'),
          'synthetic-storage-token', 'storage@example.test');
        const mail: JmapEmail = {
          id: 'synthetic_body', threadId: 'synthetic_thread', mailboxIds: ['inbox'], keywords: [],
          messageIds: ['synthetic-body@example.test'], from: [], to: [], cc: [], replyTo: [],
          subject: 'Synthetic storage review', preview: 'Synthetic cached summary', receivedAt: 0,
          textBody: 'Synthetic storage body 中文\n'.repeat(4096),
          htmlBody: '<p>Synthetic storage body 中文</p>'.repeat(4096),
          hasAttachment: false, hasHtmlBody: true, bodyTruncated: false, bodyEncodingProblem: false
        };
        await store.mail.saveEmail(account.id, mail);
        const original = await store.mail.email(account.id, mail.id, true);
        expect(original !== null).assertTrue();
        if (!original) { throw new Error('Synthetic cached body missing'); }
        const index = await store.mail.cachedMessages(account.id, false);
        expect(await store.mail.hasSqlSummaryProjection()).assertTrue();
        expect(index.length).assertEqual(1);
        expect(index[0].summaryOnly).assertTrue();
        expect(index[0].mail.cachedBodyAvailable).assertTrue();
        expect(index[0].mail.textBody === null && index[0].mail.htmlBody === null).assertTrue();
        expect(index[0].bodySavedAt).assertEqual(original.bodySavedAt);
        expect(cacheReadyForReading(index[0])).assertFalse();
        expect(JSON.stringify(index).length < 4096).assertTrue();
        await store.mail.saveView(account.id, 'inbox', index.map(record => record.mail));
        const headerView = await store.mail.view(account.id, 'inbox', true, false);
        expect(headerView?.emails[0].cachedBodyAvailable).assertTrue();
        expect(headerView?.emails[0].textBody === null).assertTrue();
        const afterProjection = await store.mail.email(account.id, mail.id, true);
        expect(afterProjection?.mail.textBody === mail.textBody && afterProjection?.mail.htmlBody === mail.htmlBody).assertTrue();
        expect(afterProjection?.bodySavedAt).assertEqual(original.bodySavedAt);
        await delegator.print('STORAGE_REVIEW_STAGE: native SQL projection active; saved body retained\n');

        const batch: JmapEmail[] = [];
        for (let position = 0; position < 65; position++) {
          const header = shallowCopyEmail(index[0].mail);
          header.id = `synthetic_batch_${position}`; header.threadId = header.id;
          header.messageIds = []; header.cachedBodyAvailable = undefined;
          batch.unshift(header);
        }
        await store.mail.saveView(account.id, 'inbox', batch, 65, 'synthetic-query');
        await store.mail.markDirty(account.id, 'synthetic_batch_1');
        const withDirty = await store.mail.view(account.id, 'inbox', true, false);
        expect(withDirty?.emails.map(value => value.id).join(',')).assertEqual(batch.map(value => value.id).join(','));
        expect(withDirty?.stateDirty).assertTrue();
        expect(withDirty?.nextPosition).assertEqual(65);
        expect(withDirty?.queryState).assertEqual('synthetic-query');
        const cleanBatch = await store.mail.view(account.id, 'inbox', false, false);
        expect(cleanBatch?.emails.map(value => value.id).join(',')).assertEqual(batch.filter(value => value.id !== 'synthetic_batch_1').map(value => value.id).join(','));
        expect(cleanBatch?.stateDirty).assertFalse();
        expect((await store.mail.email(account.id, mail.id, true))?.bodySavedAt).assertEqual(original.bodySavedAt);
        await delegator.print('STORAGE_REVIEW_STAGE: 65-header batch preserves order, dirty filtering and original body\n');

        const previousCache = store.mail;
        const pendingWrite = store.saveComposition(account.id, { senderName: 'Synthetic Sender', signature: 'Saved before close' });
        const closing = store.close();
        expect(store.close() === closing).assertTrue();
        const reopening = store.open(ability.context);
        await pendingWrite; await closing; await reopening;
        expect((await store.composition(account.id)).signature).assertEqual('Saved before close');
        const reopenedBody = await store.mail.email(account.id, mail.id, true);
        expect(reopenedBody?.mail.textBody === mail.textBody && reopenedBody?.mail.htmlBody === mail.htmlBody).assertTrue();
        expect(reopenedBody?.bodySavedAt).assertEqual(original.bodySavedAt);
        let obsoleteRejected = false;
        try { await previousCache.cachedMessages(account.id, false); } catch (_) { obsoleteRejected = true; }
        expect(obsoleteRejected).assertTrue();
        expect(await store.mail.hasSqlSummaryProjection()).assertTrue();
        expect(ability.navigationCallCount()).assertEqual(0);
        expect(ability.navigationViolationCount()).assertEqual(0);
        await delegator.print('STORAGE_REVIEW_STAGE: close joined; queued write retained; stale cache rejected; zero mail calls\n');
      } finally {
        await store.open(ability.context);
        for (const saved of await store.list()) { await store.remove(saved.id); }
        await store.close();
        await ability.context.terminateSelf(); await delegator.removeAbilityMonitor(monitor);
      }
      await delegator.print('STORAGE_REVIEW_RESULT: native header projection, original offline body and close/reopen ordering passed\n');
    });
  });
}
