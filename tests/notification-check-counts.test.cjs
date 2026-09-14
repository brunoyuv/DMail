const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

const options = { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS };
const modelModule = { exports: {} };
new Function('module', 'exports', ts.transpileModule(fs.readFileSync(
  'harmony/entry/src/main/ets/mail/notifications/NotificationModel.ts', 'utf8'), { compilerOptions: options }).outputText)(modelModule, modelModule.exports);
const { compareJmapInbox, NotificationAccountState } = modelModule.exports;
const service = fs.readFileSync('harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets', 'utf8');
const start = service.indexOf('class CheckEnvironment '), end = service.indexOf('interface ForegroundWatch ');
assert.ok(start >= 0 && end > start, 'Shipping CheckEnvironment must remain present');
const compiled = ts.transpileModule(`export ${service.slice(start, end)}`, { compilerOptions: options }).outputText;

function fixture() {
  const state = { boxesFail: false, guardFail: false, recordFail: false, boxes: [
    { id: 'inbox', role: 'inbox', unreadEmails: 137, totalEmails: 500, countsKnown: true }
  ], mails: [{ id: 'old', receivedAt: 100, keywords: [] }], records: [], calls: [] };
  class NativeJmapAccountCore {
    async mailboxes(...args) {
      state.calls.push({ method: 'mailboxes', args });
      if (state.boxesFail) throw new Error('Synthetic metadata failure');
      return state.boxes;
    }
    async emailPage(...args) {
      state.calls.push({ method: 'emailPage', args });
      return { emails: state.mails, nextPosition: 50, notFound: [] };
    }
  }
  const account = { id: 'synthetic-account', serverId: 'synthetic-server', sessionUrl: 'https://example.test/jmap' };
  const store = { credentials: () => ({ authorization: async () => 'synthetic-auth' }), badges: {
    beginCheck: async () => { if (state.guardFail) throw new Error('Synthetic count guard failure'); return { revision: 1, settingsRevision: 2 }; },
    record: async (accountId, guard, count, mailboxId) => {
      if (state.recordFail) throw new Error('Synthetic count write failure');
      if (guard) state.records.push({ accountId, count, mailboxId });
    }
  } };
  const module = { exports: {} };
  new Function('module', 'exports', 'NativeJmapAccountCore', 'NativeImapClient', 'NotificationPlatform',
    'MailBannerNotice', 'compareJmapInbox', compiled)(module, module.exports, NativeJmapAccountCore,
    class { constructor() { throw new Error('Unexpected IMAP call'); } }, {}, {}, compareJmapInbox);
  const environment = new module.exports.CheckEnvironment({}, store, [account], false, () => false);
  const settings = Object.assign(new NotificationAccountState(), { accountId: account.id, enabled: true });
  return { state, environment, settings, account };
}

test('JMAP first check reuses Inbox discovery metadata for its full unread total without treating the bounded page as a count', async () => {
  const f = fixture();
  const result = await f.environment.check(f.settings);
  assert.equal(result.newMessages, 0); assert.equal(result.unreadEmails, 137);
  assert.deepEqual(f.state.calls.map(value => value.method), ['mailboxes', 'emailPage']);
  assert.deepEqual(f.state.records, [{ accountId: f.account.id, count: 137, mailboxId: 'inbox' }]);
});

test('JMAP existing Inbox check retains new arrivals when the optional full-count metadata request fails', async () => {
  const f = fixture(); f.settings.mailboxId = 'inbox';
  f.settings.cursor = compareJmapInbox('', 'inbox', [{ id: 'old', receivedAt: 100, unread: true }], null, []).state;
  f.state.mails.unshift({ id: 'new', receivedAt: 200, keywords: [] }); f.state.boxesFail = true;
  const result = await f.environment.check(f.settings);
  assert.equal(result.newMessages, 1); assert.equal(result.unreadEmails, undefined);
  assert.deepEqual(f.state.calls.map(value => value.method), ['emailPage', 'mailboxes']);
  assert.equal(f.state.records.length, 0);
});

test('JMAP unknown or inconsistent mailbox counts never replace a saved full unread total', async () => {
  for (const fields of [{ countsKnown: false }, { unreadEmails: 501 }, { unreadEmails: -1 }, { unreadEmails: 2.5 }]) {
    const f = fixture(); Object.assign(f.state.boxes[0], fields);
    const result = await f.environment.check(f.settings);
    assert.equal(result.newMessages, 0); assert.equal(result.unreadEmails, undefined);
    assert.equal(f.state.records.length, 0);
  }
});

test('JMAP badge guard and persistence failures do not fail the successful mailbox check', async () => {
  for (const failure of ['guardFail', 'recordFail']) {
    const f = fixture(); f.state[failure] = true;
    const result = await f.environment.check(f.settings);
    assert.equal(result.mailboxId, 'inbox'); assert.equal(result.newMessages, 0);
    assert.equal(f.state.calls.filter(value => value.method === 'emailPage').length, 1);
    assert.equal(f.state.records.length, 0);
  }
});
