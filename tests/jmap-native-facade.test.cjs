const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JmapClient, JmapError, JmapDraftError } = require('../.tools/test-output/mail/jmap/JmapClient.js');
const endpoint = 'https://mail.example/session';
const parseUrl = (value, base) => new URL(value, base);
const credentials = { authorization: async () => 'Bearer fixture-token' };
function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}
function draft() {
  return { from: null, to: [{ name: '', email: 'unfinished<' }], cc: [], bcc: [], replyTo: [],
    subject: 'Original', textBody: '鸿蒙', inReplyTo: [], references: [] };
}

test('Production refuses a transport-only client and does not fall back after native failure', async () => {
  let httpCalls = 0, nativeCalls = 0;
  const platform = { parseUrl, send: async () => { httpCalls++; throw new Error('must not use HTTP fallback'); } };
  assert.throws(() => new JmapClient(endpoint, platform, credentials), e => e.code === 'nativeCoreUnavailable');
  const failure = new JmapError('network');
  platform.accountCore = { mailboxes: async () => { nativeCalls++; throw failure; } };
  const client = new JmapClient(endpoint, platform, credentials);
  await assert.rejects(client.mailboxes('selected'), e => e === failure);
  assert.equal(nativeCalls, 1);
  assert.equal(httpCalls, 0);
});

test('Production coalesces discovery, isolates returned sessions and can retry failed discovery explicitly', async () => {
  let calls = 0;
  const gate = deferred();
  const source = { apiUrl: 'https://mail.example/api', state: 's', accounts: [{ id: 'selected' }],
    primaryAccountId: 'selected', maxObjectsInGet: 50 };
  const client = new JmapClient(endpoint, { parseUrl, accountCore: {
    connect: async () => { calls++; if (calls === 1) { await gate.promise; throw new JmapError('network'); }
      return { session: source, maxRequestBytes: 4096 }; }
  } }, credentials);
  const a = client.connect(), b = client.connect();
  gate.resolve();
  const failed = await Promise.allSettled([a, b]);
  assert.ok(failed.every(result => result.status === 'rejected'));
  assert.equal(calls, 1);
  const [one, two] = await Promise.all([client.connect(), client.connect()]);
  one.accounts[0].id = 'changed';
  assert.equal(two.accounts[0].id, 'selected');
  assert.equal((await client.connect()).accounts[0].id, 'selected');
  assert.equal(calls, 2);
});

test('Draft and undo inputs are captured before asynchronous credentials, without retrying an uncertain create', async () => {
  const gate = deferred(), calls = [];
  const failure = new JmapDraftError('draftOutcomeUnknown', true);
  const client = new JmapClient(endpoint, { parseUrl, accountCore: {
    createDraft: async (...args) => { calls.push(['create', ...args]); throw failure; },
    undoArchive: async (...args) => { calls.push(['undo', ...args]); }
  } }, { authorization: () => gate.promise });
  const input = draft(), undo = { accountId: 'selected', emailId: 'e1', inboxId: 'inbox', archiveId: 'archive',
    addedArchive: true, expectedMailboxIds: ['archive', 'label'] };
  const creating = client.createDraft('selected', input), undoing = client.undoArchive(undo);
  input.subject = 'Edited'; input.to[0].email = 'different@example.com'; undo.expectedMailboxIds.push('changed');
  assert.equal(calls.length, 0);
  gate.resolve('Bearer restored-token');
  await assert.rejects(creating, e => e === failure && e.mayHaveCreated);
  await undoing;
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], ['create', endpoint, 'Bearer restored-token', 'selected', draft()]);
  assert.deepEqual(calls[1][3].expectedMailboxIds, ['archive', 'label']);
});

test('Credential failure and unsafe setup endpoints cannot dispatch native writes', async () => {
  let dispatched = 0;
  const platform = { parseUrl, accountCore: { createDraft: async () => { dispatched++; } } };
  for (const bad of ['http://mail.example/session', 'https://user:secret@mail.example/session',
    endpoint + '#fragment', endpoint + '\n', 'https://mail.example\\session']) {
    assert.throws(() => new JmapClient(bad, platform, credentials), e => e.code === 'unsafeEndpoint');
  }
  const failure = new JmapError('authenticationRequired');
  const client = new JmapClient(endpoint, platform, { authorization: async () => { throw failure; } });
  await assert.rejects(client.createDraft('selected', draft()), e => e === failure);
  assert.equal(dispatched, 0);
});
