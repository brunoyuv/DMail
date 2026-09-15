// Shipping Swift/NAPI path with only the existing loopback encoding fixture.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import deviceInfo from '@ohos.deviceInfo';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { relationalStore } from '@kit.ArkData';
import { MailCache } from '../../../main/ets/data/MailCache';
import { cacheEmail, decodeCachedEmail } from '../../../main/ets/data/MailCacheModel';
import { MailSyncStore } from '../../../main/ets/data/MailSyncStore';
import { encodeMailSyncEmail } from '../../../main/ets/data/MailSyncModel';
import { PictureCache } from '../../../main/ets/data/PictureCache';
import { PreparedDocumentStore } from '../../../main/ets/data/PreparedDocumentStore';
import { PreparedMailDocument, encodePreparedDocument } from '../../../main/ets/data/PreparedDocumentModel';
import { plainTextMailHtml, preparedMailDocument } from '../../../main/ets/mail/html/HtmlDocument';
import { stableMessageKey } from '../../../main/ets/mail/Conversation';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapEmail, JmapEmailPage, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

class SyncCredentials implements JmapCredentials {
  mode: string = 'encoding';
  async authorization(): Promise<string> {
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(
      new util.TextEncoder().encodeInto(this.mode + ':fixture-password'));
  }
}
interface SyncFixtureSession {
  mode: string; commands: string[]; closed: boolean; violation?: string;
  encodingSplitResponses?: number; encodingUnsolicitedUpdates?: number;
}
interface SyncFixtureConnections { server: number; }
interface SyncFixtureStats {
  sessions: SyncFixtureSession[];
  connections: SyncFixtureConnections;
  active: number;
  violations: string[];
}
function pause(ms: number): Promise<void> { return new Promise<void>(resolve => { setTimeout(resolve, ms); }); }
function id(uid: number): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(
    JSON.stringify({ mailbox: 'INBOX', uid, validity: 77 }))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function stats(active?: number): Promise<SyncFixtureStats> {
  for (let attempt = 0; attempt < 60; attempt++) {
    const request = http.createHttp();
    let value: SyncFixtureStats;
    try {
      const response = await request.request('http://127.0.0.1:9760/stats', {
        connectTimeout: 2000, readTimeout: 2000, usingCache: false
      });
      expect(response.responseCode).assertEqual(200);
      value = JSON.parse(response.result as string) as SyncFixtureStats;
    } finally { request.destroy(); }
    if (active === undefined || value.active === active) { return value; }
    await pause(50);
  }
  throw new Error('Synthetic IMAP connections did not settle');
}
function exactMail(mail: JmapEmail | null, uid: number): void {
  expect(mail !== null).assertTrue();
  const value = mail!;
  expect(value.id).assertEqual(id(uid));
  expect(value.from[0].name).assertEqual('山田 太郎');
  expect(value.from[0].email).assertEqual('sender@example.test');
  expect(value.messageIds.join(',')).assertEqual(`<encoding-${uid}@example.test>`);
  expect(value.references?.join(',')).assertEqual('encoding-root@example.test');
  expect(value.receivedAt).assertEqual(1789293600000);
  expect(value.keywords.includes('$seen')).assertTrue();
  expect(value.bodyEncodingProblem).assertFalse(); expect(value.bodyTruncated).assertFalse();
  if (uid === 201) {
    expect(value.subject).assertEqual('UTF-8 中文'); expect(value.textBody).assertEqual('中文');
    expect(value.htmlBody ?? null).assertNull();
  } else if (uid === 202) {
    expect(value.subject).assertEqual('Shift_JIS 日本語'); expect(value.textBody).assertEqual('日本語');
    expect(value.htmlBody ?? null).assertNull();
  } else {
    expect(value.subject).assertEqual('Re: 中文 café 📨 update'); expect(value.textBody).assertNull();
    expect(value.htmlBody).assertEqual('<p>中文 café 😀</p>');
  }
}
async function rejected(operation: () => Promise<JmapEmail | null>): Promise<void> {
  let code = '';
  try { await operation(); } catch (error) { code = (error as JmapError).code; }
  expect(code).assertEqual('network');
}

function recoveryMail(id: string, failed: boolean): JmapEmail {
  return { id, threadId: id, messageIds: [id + '@example.test'], mailboxIds: ['inbox'],
    keywords: ['$flagged'], from: [], to: [], replyTo: [], subject: 'Synthetic recovery ' + id,
    preview: 'Preserved header preview', receivedAt: 123,
    textBody: failed ? null : 'A usable saved partial body 中文',
    htmlBody: failed ? null : '<p>A usable saved partial body 中文</p>',
    bodyTruncated: !failed, bodyEncodingProblem: true, hasHtmlBody: !failed, hasAttachment: true,
    attachments: [{ id: '2', name: 'report.pdf', contentType: 'application/pdf', size: 100, sizeIsEncoded: true }] };
}
async function scalar(db: relationalStore.RdbStore, sql: string, args: relationalStore.ValueType[] = []): Promise<string> {
  const rows = await db.querySql(sql, args);
  try { expect(rows.goToFirstRow()).assertTrue(); return rows.getString(0); }
  finally { rows.close(); }
}
async function numberValue(db: relationalStore.RdbStore, sql: string): Promise<number> {
  const rows = await db.querySql(sql);
  try { expect(rows.goToFirstRow()).assertTrue(); return rows.getLong(0); }
  finally { rows.close(); }
}
async function seedRecovery(db: relationalStore.RdbStore, mail: JmapEmail, html: string, savedAt: number,
  completedAt: number = savedAt): Promise<string[]> {
  const payload = JSON.stringify(cacheEmail(mail, true, null, savedAt)), key = stableMessageKey(mail);
  const document: PreparedMailDocument = { version: 1, messageKey: key, bodySavedAt: savedAt,
    savedAt, html, pictures: [] };
  const prepared = encodePreparedDocument(document);
  await db.executeSql("INSERT INTO mail_cache (account_id, kind, cache_key, payload, dirty) VALUES ('synthetic', 'email', ?, ?, 1)", [mail.id, payload]);
  await db.executeSql("INSERT INTO prepared_documents (account_id, message_key, body_saved_at, state, payload) VALUES ('synthetic', ?, ?, 'ready', ?)", [key, savedAt, prepared]);
  await db.executeSql("INSERT INTO mail_sync_jobs (account_id, email_id, payload, stage, attempts, retry_at, body_saved_at, message_key, queued_at) VALUES ('synthetic', ?, ?, 'done', 0, 0, ?, ?, ?)",
    [mail.id, encodeMailSyncEmail(mail), completedAt, key, savedAt]);
  return [payload, prepared];
}

export default function tests(): void {
  describe('SyncSession', () => {
    it('body_sync_reuses_tls_auth_and_preserves_unicode_with_explicit_retirement', 0, async () => {
      expect(deviceInfo.abiList.includes('x86_64')).assertTrue();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const credentials = new SyncCredentials();
      const core = new NativeImapClient('imaps://localhost:9761', credentials);
      const sessionId = util.generateRandomUUID(true), freshId = util.generateRandomUUID(true), emptyId = util.generateRandomUUID(true);
      try {
        const start = await stats(0); expect(start.sessions.length).assertEqual(0);
        const ordinary: JmapEmail[] = [];
        for (const uid of [201, 202, 203]) {
          const mail = await core.readEmail('default', id(uid)); exactMail(mail, uid); ordinary.push(mail!);
        }
        const baseline = await stats(0);
        expect(baseline.sessions.length).assertEqual(3); expect(baseline.connections.server).assertEqual(3);
        expect(baseline.sessions.every(session => session.commands.filter(command => command === 'LOGIN').length === 1)).assertTrue();
        expect(baseline.sessions[0].encodingSplitResponses).assertEqual(1);
        expect(baseline.sessions[1].encodingUnsolicitedUpdates).assertEqual(2);
        await delegator.print('SYNC_SESSION_PHASE: ordinary bodies=3 tls=3 login=3 active=0\n');

        for (let index = 0; index < ordinary.length; index++) {
          const uid = 201 + index;
          const mail = await core.readEmailForSync('default', id(uid), sessionId);
          exactMail(mail, uid);
          expect(mail).assertDeepEquals(ordinary[index]);
        }
        const pooled = await stats(1);
        expect(pooled.sessions.length).assertEqual(4); expect(pooled.connections.server).assertEqual(4);
        expect(pooled.sessions[3].commands.filter(command => command === 'LOGIN').length).assertEqual(1);
        expect(pooled.sessions[3].encodingSplitResponses).assertEqual(1);
        expect(pooled.sessions[3].encodingUnsolicitedUpdates).assertEqual(2);
        await delegator.print('SYNC_SESSION_PHASE: pooled bodies=3 additional_tls=1 additional_login=1 active=1\n');
        await delegator.print('SYNC_FETCH_ASSEMBLY_RESULT: split MIME/body FETCH records and unrelated flag updates preserve the exact requested Unicode body in ordinary and pooled reads\n');

        // A changed authorization cannot adopt the old authenticated channel.
        credentials.mode = 'account';
        await rejected(() => core.readEmailForSync('default', id(201), sessionId));
        credentials.mode = 'encoding';
        await core.closeSyncSession(sessionId);
        const retired = await stats(0); expect(retired.connections.server).assertEqual(4);
        // A fresh ArkTS client proves this rejection comes from native UUID
        // retirement, not merely the caller's in-memory lease bookkeeping.
        const late = new NativeImapClient('imaps://localhost:9761', credentials);
        await rejected(() => late.readEmailForSync('default', id(201), sessionId));
        expect((await stats(0)).connections.server).assertEqual(4);
        exactMail(await late.readEmailForSync('default', id(202), freshId), 202);
        await late.closeSyncSession(freshId);
        const finished = await stats(0);
        expect(finished.connections.server).assertEqual(5); expect(finished.sessions.length).assertEqual(5);
        expect(finished.violations.length).assertEqual(0);
        expect(finished.sessions.every(session => session.mode === 'encoding' && session.closed &&
          !session.violation && session.commands.filter(command => command === 'LOGIN').length === 1)).assertTrue();
        await delegator.print('SYNC_SESSION_RESULT: 3 ordinary bodies used 3 TLS/auth sessions; same 3 bodies used 1 sync session with identical Unicode and metadata; changed owner and retired UUID opened no connection; fresh UUID succeeded; all 5 connections closed\n');

        credentials.mode = 'emptybody';
        for (const uid of [301, 302, 303, 304, 305, 306]) {
          const message = await core.readEmailForSync('default', id(uid), emptyId);
          expect(message !== null).assertTrue();
          const value = message!;
          expect(value.id).assertEqual(id(uid));
          if (uid <= 303) {
            expect(value.bodyEncodingProblem).assertFalse(); expect(value.bodyTruncated).assertFalse();
            expect(value.htmlBody ?? null).assertEqual(uid === 302 ? '' : null);
            expect(value.textBody).assertEqual(uid === 302 ? null : '');
            expect(value.hasHtmlBody).assertEqual(uid === 302);
            if (uid === 303) {
              expect(value.hasAttachment).assertTrue(); expect(value.attachments?.length).assertEqual(1);
              expect(value.attachments![0].name).assertEqual('report.pdf');
            }
          } else if (uid === 306) {
            // Retain the existing malformed-transfer fallback when the raw
            // bytes themselves are usable text; this is not a blank failure.
            expect(value.bodyEncodingProblem).assertFalse(); expect(value.bodyTruncated).assertFalse();
            expect(value.textBody).assertEqual('Y'); expect(value.htmlBody ?? null).assertNull();
          } else {
            expect(value.bodyEncodingProblem).assertTrue();
            expect(value.textBody).assertNull(); expect(value.htmlBody ?? null).assertNull();
          }
        }
        await core.closeSyncSession(emptyId);
        const emptyFinished = await stats(0);
        expect(emptyFinished.connections.server).assertEqual(6);
        expect(emptyFinished.sessions[5].mode).assertEqual('emptybody');
        expect(emptyFinished.sessions[5].closed).assertTrue();
        expect(emptyFinished.sessions[5].violation === undefined).assertTrue();
        expect(emptyFinished.violations.length).assertEqual(0);
        await delegator.print('SYNC_EMPTY_BODY_RESULT: zero-byte text and HTML return explicit empty strings; attachment-only metadata preserved; invalid UTF-8 and missing advertised text remain failed-empty for durable recovery; malformed transfer declaration preserves usable raw text; 6 cases used 1 additional TLS/auth session and closed\n');
      } finally {
        await core.closeSyncSession(sessionId).catch(() => {});
        await core.closeSyncSession(freshId).catch(() => {});
        await core.closeSyncSession(emptyId).catch(() => {});
      }
    });
    it('native_rdb_recovers_failed_empty_023_once_and_preserves_usable_partial_mail', 0, async () => {
      expect(deviceInfo.abiList.includes('x86_64')).assertTrue();
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext().getApplicationContext().createModuleContext('entry');
      expect(context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const config: relationalStore.StoreConfig = { name: 'sync_failed_empty_023_' + util.generateRandomUUID(true) + '.db',
        encrypt: true, securityLevel: relationalStore.SecurityLevel.S3 };
      const db = await relationalStore.getRdbStore(context, config);
      try {
        await db.executeSql('CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT NOT NULL)');
        await db.executeSql("INSERT INTO accounts (id, status) VALUES ('synthetic', 'ready')");
        // Initialize the shipping sync schema before body tables exist; the
        // migration must defer its completion marker until those tables exist.
        await MailSyncStore.initialize(db);
        expect(await numberValue(db, 'SELECT count(*) FROM mail_sync_repairs')).assertEqual(0);
        await MailCache.initialize(db); await PreparedDocumentStore.initialize(db);
        const savedAt = Date.now() - 1000;
        const blank = preparedMailDocument(plainTextMailHtml(''), false, 0)
          .replace('img-src data:;', 'img-src data: https://mail.invalid;')
          .replace('iframe,object,embed,input,button,textarea,select,video,audio{display:none!important}',
            'iframe,object,embed,form,input,button,textarea,select,video,audio{display:none!important}');
        expect(blank.includes('embed,form,input')).assertTrue();
        const failed = recoveryMail('failed_023', true), valid = recoveryMail('partial_023', false);
        // A competing completion can hold an older timestamp than the saved
        // failed body/document. The current raw-payload guard still proves
        // recovery is needed, and must not leave that old DONE marker behind.
        await seedRecovery(db, failed, blank, savedAt, savedAt - 10);
        expect(await numberValue(db, "SELECT body_saved_at FROM mail_sync_jobs WHERE email_id = 'failed_023'")).assertEqual(savedAt - 10);
        const original = await seedRecovery(db, valid, preparedMailDocument(valid.htmlBody!, false, 0), savedAt);
        await db.executeSql('CREATE TABLE recovery_mutations (changes INTEGER NOT NULL)');
        await db.executeSql('INSERT INTO recovery_mutations VALUES (0)');
        await db.executeSql('CREATE TRIGGER recovery_mail_update AFTER UPDATE ON mail_cache BEGIN UPDATE recovery_mutations SET changes = changes + 1; END');
        await db.executeSql('CREATE TRIGGER recovery_doc_delete AFTER DELETE ON prepared_documents BEGIN UPDATE recovery_mutations SET changes = changes + 1; END');
        await db.executeSql('CREATE TRIGGER recovery_job_update AFTER UPDATE ON mail_sync_jobs BEGIN UPDATE recovery_mutations SET changes = changes + 1; END');

        await MailSyncStore.initialize(db);
        const recovered = decodeCachedEmail(await scalar(db, "SELECT payload FROM mail_cache WHERE cache_key = 'failed_023'"));
        expect(recovered.bodySavedAt).assertNull();
        expect(recovered.mail.subject).assertEqual(failed.subject);
        expect(recovered.mail.preview).assertEqual(failed.preview);
        expect(recovered.mail.keywords.includes('$flagged')).assertTrue();
        expect(recovered.mail.attachments?.[0].name).assertEqual('report.pdf');
        expect(await numberValue(db, "SELECT dirty FROM mail_cache WHERE cache_key = 'failed_023'")).assertEqual(1);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'failed_023'")).assertEqual('body');
        expect(await numberValue(db, "SELECT body_saved_at FROM mail_sync_jobs WHERE email_id = 'failed_023'")).assertEqual(0);
        expect(await numberValue(db, "SELECT count(*) FROM prepared_documents WHERE message_key = '" + stableMessageKey(failed) + "'")).assertEqual(0);
        expect(await scalar(db, "SELECT payload FROM mail_cache WHERE cache_key = 'partial_023'")).assertEqual(original[0]);
        expect(await scalar(db, 'SELECT payload FROM prepared_documents WHERE message_key = ?', [stableMessageKey(valid)])).assertEqual(original[1]);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'partial_023'")).assertEqual('done');
        expect(await numberValue(db, 'SELECT count(*) FROM mail_sync_repairs WHERE version = 1')).assertEqual(1);
        const changes = await numberValue(db, 'SELECT changes FROM recovery_mutations');
        expect(changes).assertEqual(3);
        await MailSyncStore.initialize(db);
        expect(await numberValue(db, 'SELECT changes FROM recovery_mutations')).assertEqual(changes);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'failed_023'")).assertEqual('body');
        expect(await scalar(db, "SELECT payload FROM mail_cache WHERE cache_key = 'partial_023'")).assertEqual(original[0]);
        await delegator.print('SYNC_RECOVERY_RESULT: native encrypted RDB requeued one failed-empty 0.1.23 body, cleared its false saved timestamp, removed only its exact old empty document, preserved preview/dirty flags/attachment metadata and usable partial mail; second initialization changed zero rows\n');

        // Exercise installed .24 state after its migration marker already
        // exists: an explicit pending header and an absent raw row both still
        // have fresh terminal jobs. Only new mailbox registration repairs them.
        let tail: Promise<void> = Promise.resolve();
        const queue = (operation: () => Promise<void>): Promise<void> => {
          const task = tail.catch(() => {}).then(operation); tail = task.catch(() => {}); return task;
        };
        const cache = new MailCache(db, queue), sync = new MailSyncStore(db, queue);
        await PictureCache.initialize(db);
        const pictures = new PictureCache(db, queue);
        const pending = recoveryMail('pending_024', true), absent = recoveryMail('absent_024', false);
        await seedRecovery(db, pending, blank, savedAt);
        const retainedDocument = await seedRecovery(db, absent, preparedMailDocument(absent.htmlBody!, false, 0), savedAt);
        await cache.forgetEmail('synthetic', pending.id); await cache.forgetEmail('synthetic', absent.id);
        pending.bodyEncodingProblem = false;
        await cache.saveView('synthetic', 'inbox', [pending], null, 'pending-head');
        await db.executeSql('DELETE FROM prepared_documents WHERE account_id = ? AND message_key = ?', ['synthetic', stableMessageKey(pending)]);
        const pendingPayload = await scalar(db, "SELECT payload FROM mail_cache WHERE cache_key = 'pending_024'");
        expect(decodeCachedEmail(pendingPayload).bodySavedAt).assertNull();
        expect(pendingPayload.slice(0, 192).includes('"bodySavedAt":null,')).assertTrue();
        const pictureManifest = '[{"url":"https://images.example.test/saved.png","failure":"network","status":0}]';
        await db.executeSql('INSERT INTO picture_snapshot (account_id, message_key, manifest) VALUES (?, ?, ?)',
          ['synthetic', stableMessageKey(absent), pictureManifest]);
        expect(await pictures.snapshotAttempted('synthetic', stableMessageKey(absent))).assertTrue();
        await MailSyncStore.initialize(db);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'pending_024'")).assertEqual('done');
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'absent_024'")).assertEqual('done');
        const beforeRegistration = await numberValue(db, 'SELECT changes FROM recovery_mutations');
        const page: JmapEmailPage = { accountId: 'server', emails: [pending, absent, valid], position: 0,
          nextPosition: null, queryState: 'recovered-head', emailState: null, total: null, notFound: [] };
        await sync.seedPage('synthetic', 'inbox', page);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'pending_024'")).assertEqual('body');
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'absent_024'")).assertEqual('body');
        expect(await numberValue(db, 'SELECT changes FROM recovery_mutations')).assertEqual(beforeRegistration + 2);
        expect((await sync.next(['synthetic'], 'body', 10)).map(job => job.email.id).includes(pending.id)).assertTrue();
        expect((await sync.next(['synthetic'], 'body', 10)).map(job => job.email.id).includes(absent.id)).assertTrue();
        expect(await scalar(db, 'SELECT payload FROM prepared_documents WHERE message_key = ?', [stableMessageKey(absent)])).assertEqual(retainedDocument[1]);
        expect(await scalar(db, 'SELECT manifest FROM picture_snapshot WHERE message_key = ?', [stableMessageKey(absent)])).assertEqual(pictureManifest);
        expect(await pictures.snapshotAttempted('synthetic', stableMessageKey(absent))).assertTrue();
        expect(await scalar(db, "SELECT payload FROM mail_cache WHERE cache_key = 'partial_023'")).assertEqual(original[0]);
        expect(await scalar(db, 'SELECT payload FROM prepared_documents WHERE message_key = ?', [stableMessageKey(valid)])).assertEqual(original[1]);
        expect(await scalar(db, "SELECT stage FROM mail_sync_jobs WHERE email_id = 'partial_023'")).assertEqual('done');
        const retryAt = Date.now() + 60000;
        await sync.defer('synthetic', pending.id, retryAt);
        const beforeRepeat = await numberValue(db, 'SELECT changes FROM recovery_mutations');
        await sync.enqueue('synthetic', [pending, absent, valid]);
        expect(await numberValue(db, "SELECT retry_at FROM mail_sync_jobs WHERE email_id = 'pending_024'")).assertEqual(retryAt);
        expect(await numberValue(db, 'SELECT changes FROM recovery_mutations')).assertEqual(beforeRepeat);
        await tail;
        await delegator.print('SYNC_PENDING_REPAIR_RESULT: native encrypted RDB repaired stale completion timestamps; after the 0.1.24 migration marker, mailbox registration requeued both null and absent raw bodies while retaining usable partial mail, immutable shared HTML, completed picture attempts and retry backoff\n');
      } finally {
        await db.close(); await relationalStore.deleteRdbStore(context, config);
      }
    });
  });
}
