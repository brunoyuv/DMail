const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

const source = fs.readFileSync('harmony/entry/src/main/ets/mail/imap/NativeImapClient.ets', 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture(check) {
  const requests = [], module = { exports: {} };
  class JmapError extends Error { constructor(code) { super(code); this.code = code; } }
  new Function('require', 'module', 'exports', compiled)(name => {
    if (name === 'libthunderbird.so') return { imapAccountRequest: async raw => {
      requests.push(JSON.parse(raw)); return JSON.stringify({ inboxCheck: check });
    } };
    if (name.endsWith('/JmapClient')) return { JmapError };
    throw new Error(`Unexpected dependency ${name}`);
  }, module, module.exports);
  const client = new module.exports.NativeImapClient('imaps://example.test:993',
    { authorization: async () => 'Synthetic authorization' }, 'synthetic');
  return { client, requests };
}

test('Inbox check carries the complete unread total independently of its bounded arrival count', async () => {
  const f = fixture({ state: 'synthetic-watermark', mailboxId: 'inbox', newMessages: 2, unreadEmails: 731 });
  const value = await f.client.checkInbox('default', 'previous-watermark');
  assert.equal(value.newMessages, 2); assert.equal(value.unreadEmails, 731);
  assert.equal(f.requests.length, 1);
  assert.deepEqual(f.requests.map(value => value.operation), ['checkInbox']);
  assert.equal(f.requests[0].queryState, 'previous-watermark');
});

test('Optional count unavailable and known zero remain distinct without losing arrival detection', async () => {
  for (const unreadEmails of [undefined, 0]) {
    const f = fixture({ state: 'synthetic-watermark', mailboxId: 'inbox', newMessages: 3, unreadEmails });
    const value = await f.client.checkInbox('default');
    assert.equal(value.newMessages, 3); assert.equal(value.unreadEmails, unreadEmails);
    assert.equal(f.requests.length, 1);
  }
});

test('Malformed native unread counts cannot enter the persisted count path', async () => {
  for (const unreadEmails of [-1, 0.5, '7', null, Number.MAX_SAFE_INTEGER + 1]) {
    const f = fixture({ state: 'synthetic-watermark', mailboxId: 'inbox', newMessages: 0, unreadEmails });
    await assert.rejects(f.client.checkInbox('default'), error => error.code === 'invalidResponse');
  }
});
