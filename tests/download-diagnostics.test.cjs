const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
function load(path, imports) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(path, 'utf8'), { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  new Function('require', 'module', 'exports', source)(name => {
    if (name === '@kit.ArkTS' && !(name in imports)) return { util: { generateRandomUUID: () => require('node:crypto').randomUUID() } };
    assert.ok(name in imports, name); return imports[name];
  }, module, module.exports);
  return module.exports;
}
const root = 'harmony/entry/src/main/ets/';
class JmapError extends Error {
  constructor(code, status, authenticationStage) { super(code); this.code = code; this.authenticationStage = authenticationStage; }
}
function clientFixture(response, credentials = { authorization: async () => 'Bearer synthetic' }) {
  const requests = [];
  const { NativeImapClient } = load(root + 'mail/imap/NativeImapClient.ets', {
    '../jmap/JmapClient': { JmapError },
    'libthunderbird.so': { imapAccountRequest: async raw => {
      const request = JSON.parse(raw); requests.push(request);
      assert.equal(request.downloadDiagnostics, undefined);
      assert.equal(request.diagnosticAttempt, undefined);
      if (request.operation === 'closeSyncSession') return JSON.stringify({ state: 'closed' });
      return JSON.stringify(response(request));
    } }
  });
  return { client: new NativeImapClient('imaps://synthetic.invalid', credentials, 'synthetic'), requests };
}
test('Shipping app has no download diagnostic controls, logger initialization or export resources', () => {
  assert.equal(fs.existsSync(root + 'mail/MailDownloadLog.ets'), false);
  for (const file of ['pages/Settings.ets', 'entryability/EntryAbility.ets', 'mail/MailMessageLoader.ets', 'mail/imap/NativeImapClient.ets']) {
    assert.doesNotMatch(fs.readFileSync(root + file, 'utf8'), /MailDownloadLog|download_log_|downloadDiagnostics/);
  }
  for (const language of ['base', 'zh_CN']) {
    const resources = JSON.parse(fs.readFileSync('harmony/entry/src/main/resources/' + language + '/element/string.json'));
    assert.ok(resources.string.every(row => !row.name.startsWith('download_log_')));
  }
});
test('Read, page and connect requests never opt into native diagnostic collection', async () => {
  const f = clientFixture(request => request.operation === 'connect' ? { session: { accountId: 'default' } } :
    request.operation === 'emailPage' ? { page: { emails: [], position: 0 } } :
    { email: null, downloadTrace: [{ secret: 'ignored' }], lateDownloadCompletions: [] });
  await f.client.connect(); await f.client.emailPage('default', 'inbox');
  assert.equal(await f.client.readEmail('default', 'message'), null);
  await f.client.closeReadSession();
  assert.deepEqual(f.requests.map(row => row.operation), ['connect', 'emailPage', 'readEmail', 'closeSyncSession']);
});
test('Removing diagnostics preserves native error classification and discards failed sessions', async () => {
  const f = clientFixture(() => ({ error: 'authenticationRequired', authenticationStage: 'server', downloadTrace: [] }));
  await assert.rejects(f.client.readEmail('default', 'message'), { code: 'authenticationRequired', authenticationStage: 'server' });
  assert.deepEqual(f.requests.map(row => row.operation), ['readEmail', 'closeSyncSession']);
});
test('Credential failure still prevents native requests without logging', async () => {
  const f = clientFixture(() => { throw Error('must not be called'); },
    { authorization: async () => { throw new JmapError('authenticationRequired', 0, 'credentials'); } });
  await assert.rejects(f.client.emailPage('default', 'inbox'), { code: 'authenticationRequired', authenticationStage: 'credentials' });
  assert.deepEqual(f.requests, []);
});
