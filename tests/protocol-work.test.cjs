const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
function load(file, imports, globals = {}) {
  const module = { exports: {} };
  new Function('require', 'module', 'exports', ...Object.keys(globals), compile(fs.readFileSync(file, 'utf8')))(name => {
    if (name === '@kit.ArkTS' && !(name in imports)) return { util: { generateRandomUUID: () => require('node:crypto').randomUUID() } };
    assert.ok(name in imports, `Unexpected dependency ${name}`); return imports[name];
  }, module, module.exports, ...Object.values(globals));
  return module.exports;
}
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
class JmapError extends Error { constructor(code) { super(code); this.code = code; } }
const { shallowCopyEmail } = load('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts', {});
function imapFixture(response, authorization = async () => 'Bearer synthetic-token') {
  const state = { calls: [], authorizations: 0 };
  const native = load('harmony/entry/src/main/ets/mail/imap/NativeImapClient.ets', {
    'libthunderbird.so': { imapAccountRequest: async raw => {
      const bytes = Buffer.byteLength(raw); assert.ok(bytes <= 128 * 1024, `Native request has ${bytes} bytes`);
      const request = JSON.parse(raw); state.calls.push(request); return JSON.stringify(await response(request));
    } }, '../jmap/JmapClient': { JmapError }
  });
  const client = new native.NativeImapClient('imaps://example.test', { authorization: async () => {
    state.authorizations++; return authorization();
  } }, 'synthetic');
  return { state, client };
}

test('Concurrent IMAP connect calls share credential lookup and a single native session discovery', async () => {
  const gate = deferred(), started = deferred();
  const f = imapFixture(async () => { started.resolve(); await gate.promise; return {
    session: { apiUrl: 'imaps://example.test', accounts: [{ id: 'default', name: 'Synthetic account' }] }
  }; });
  const requests = [f.client.connect(), f.client.connect(), f.client.connect()]; await started.promise;
  assert.equal(f.state.calls.length, 1); assert.equal(f.state.authorizations, 1);
  gate.resolve(); const [a, b] = await Promise.all(requests);
  a.accounts[0].name = 'Changed by one caller';
  assert.equal(b.accounts[0].name, 'Synthetic account');
  assert.equal((await f.client.connect()).accounts[0].name, 'Synthetic account');
  assert.equal(f.state.calls.length, 1);
});

test('Failed IMAP discovery is not retried automatically and a later explicit call may recover', async () => {
  let fail = true;
  const f = imapFixture(async () => fail ? { error: 'network' } : { session: { accounts: [] } });
  const failed = await Promise.allSettled([f.client.connect(), f.client.connect()]);
  assert.ok(failed.every(value => value.status === 'rejected' && value.reason.code === 'network'));
  assert.equal(f.state.calls.length, 1);
  fail = false; await f.client.connect(); assert.equal(f.state.calls.length, 2);
});

test('Long cached IMAP preview identities remain optional and cannot overflow the native request envelope', async () => {
  const f = imapFixture(async () => ({ page: { emails: [], nextPosition: null } }),
    async () => 'Bearer ' + '"'.repeat(32768));
  const mailbox = 'Synthetic/' + 'folder'.repeat(140);
  const ids = Array.from({ length: 500 }, (_, uid) => Buffer.from(JSON.stringify({ mailbox, validity: 1, uid: uid + 1 })).toString('base64url'));
  await f.client.emailPage('default', Buffer.from(JSON.stringify(mailbox)).toString('base64url'), 0, undefined, ids);
  const request = f.state.calls[0];
  assert.equal(request.operation, 'emailPage'); assert.equal(request.position, 0);
  assert.ok(request.previewKnownIds.length > 0 && request.previewKnownIds.length < ids.length);
  assert.deepEqual(request.previewKnownIds, ids.slice(0, request.previewKnownIds.length));
  assert.ok(Buffer.byteLength(JSON.stringify(request.previewKnownIds)) <= 32 * 1024 + 2);
  assert.equal(f.state.calls.length, 1);
});

test('Small preview hint sets retain order while duplicate or non-IMAP hints cannot waste the byte budget', async () => {
  const f = imapFixture(async () => ({ page: { emails: [] } }));
  await f.client.emailPage('default', 'inbox', 50, 'state', ['known_a', 'known_b', 'known_a', '', 'not an opaque id', 'x'.repeat(4097)]);
  assert.deepEqual(f.state.calls[0].previewKnownIds, ['known_a', 'known_b']);
  assert.equal(f.state.calls[0].position, 50); assert.equal(f.state.calls[0].queryState, 'state');
});

test('Pending flag and move projections preserve large bodies without serializing them or mutating source arrays', async () => {
  for (const move of [false, true]) {
    const gate = deferred(), state = { serializations: 0, network: 0, revisions: new Map() };
    const { MailOperations } = load('harmony/entry/src/main/ets/mail/MailOperations.ets', { './jmap/JmapClient': { JmapError, shallowCopyEmail }, '@kit.ArkTS': { util: { generateRandomUUID: () => 'synthetic-local-id' } } }, {
      AppStorage: { get: key => state.revisions.get(key), setOrCreate: (key, value) => state.revisions.set(key, value) },
      JSON: { parse: JSON.parse, stringify: value => { state.serializations++; return JSON.stringify(value); } }
    });
    const mail = Object.freeze({ id: 'mail', keywords: Object.freeze(['$seen']), mailboxIds: Object.freeze(['inbox']),
      textBody: 'Cached text', htmlBody: '<p>' + 'x'.repeat(2_000_000) + '</p>', attachments: Object.freeze([{ id: 'part', name: 'Synthetic' }]) });
    const store = { mail: { beginMutation: () => gate.promise, endMutation() {}, updateKeyword: async () => {}, updateMailboxes: async () => {} } };
    const client = { setKeyword: async () => { state.network++; }, archiveEmail: async () => {
      state.network++; return { expectedMailboxIds: ['archive'] };
    } };
    if (move) MailOperations.move(store, client, 'account', 'server', mail, ['archive']);
    else MailOperations.setKeyword(store, client, 'account', 'server', mail, '$flagged');
    for (let i = 0; i < 20; i++) {
      const projected = MailOperations.overlay('account', mail);
      assert.equal(projected.htmlBody, mail.htmlBody); assert.equal(projected.textBody, mail.textBody);
      assert.deepEqual(move ? projected.mailboxIds : projected.keywords, move ? ['archive'] : ['$seen', '$flagged']);
      (move ? projected.mailboxIds : projected.keywords).push('local-test-change');
      assert.deepEqual(mail.keywords, ['$seen']); assert.deepEqual(mail.mailboxIds, ['inbox']);
    }
    assert.equal(state.serializations, 0, 'Repeated UI/count projections must not encode large message bodies');
    assert.equal(state.network, 0);
    gate.resolve(true); await MailOperations.whenIdle(); assert.equal(state.network, 1);
  }
});


test('Sync reads pass a reusable ID but still resolve fresh credentials for every message', async()=>{
  let token=0;const f=imapFixture(async r=>r.operation==='closeSyncSession'?{state:'closed'}:{email:{id:r.emailId}},async()=>`Bearer synthetic-${++token}`);
  await f.client.readEmailForSync('default','one','synthetic-lease');await f.client.readEmailForSync('default','two','synthetic-lease');
  await f.client.closeSyncSession('synthetic-lease');
  assert.equal(f.state.authorizations,2);assert.deepEqual(f.state.calls.map(r=>r.operation),['readEmail','readEmail','closeSyncSession']);
  assert.deepEqual(f.state.calls.map(r=>r.syncSessionId),['synthetic-lease','synthetic-lease','synthetic-lease']);
  assert.deepEqual(f.state.calls.map(r=>r.authorization),['Bearer synthetic-1','Bearer synthetic-2','']);
  assert.equal(f.state.calls[2].sessionUrl,'');assert.equal(f.state.calls[2].username,undefined);
});

test('Closing during credential refresh prevents a late native read after pause',async()=>{
  const gate=deferred();const f=imapFixture(async()=>({state:'closed'}),()=>gate.promise);
  const read=f.client.readEmailForSync('default','one','old-lease');await Promise.resolve();
  await f.client.closeSyncSession('old-lease');gate.resolve('Bearer synthetic-late');
  await assert.rejects(read,e=>e.code==='network');assert.deepEqual(f.state.calls.map(r=>r.operation),['closeSyncSession']);
});

test('Foreground IMAP body and page work recheck ownership after delayed credentials before starting native sockets', async () => {
  for (const kind of ['body', 'page']) {
    const gate = deferred(); let active = true;
    const cancelled = new Error('Synthetic cancelled');
    const beforeRequest = () => { if (!active) throw cancelled; };
    const f = imapFixture(async () => assert.fail('Retired work reached native IMAP'), async () => {
      await gate.promise; return 'Bearer synthetic';
    });
    const request = kind === 'body' ? f.client.readEmail('default', 'id', beforeRequest) :
      f.client.emailPage('default', 'inbox', 0, undefined, undefined, beforeRequest);
    await Promise.resolve();
    active = false; gate.resolve(); await assert.rejects(request, error => error === cancelled);
    assert.equal(f.state.calls.length, 0); assert.equal(f.state.authorizations, 1);
  }
});

test('Foreground JMAP body and page work also recheck ownership after credentials', async () => {
  const { JmapClient } = load('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts', {});
  for (const kind of ['body', 'page']) {
    const gate = deferred(); let active = true;
    const cancelled = new Error('Synthetic cancelled');
    const beforeRequest = () => { if (!active) throw cancelled; };
    const client = new JmapClient('https://example.test/session', { parseUrl: value => new URL(value), accountCore: {
      getEmails: async () => assert.fail('Retired body reached core'), emailPage: async () => assert.fail('Retired page reached core')
    } }, { authorization: async () => { await gate.promise; return 'Bearer synthetic'; } });
    const request = kind === 'body' ? client.readEmail('a', 'id', beforeRequest) :
      client.emailPage('a', 'inbox', 0, undefined, undefined, beforeRequest);
    active = false; gate.resolve(); await assert.rejects(request, error => error === cancelled);
  }
});

test('Foreground Inbox pages and bodies serialize on one lease and refresh credentials only when admitted', async () => {
  const gate = deferred(), started = deferred(); let active = 0, peak = 0;
  const f = imapFixture(async r => {
    if (r.operation === 'closeSyncSession') return { state: 'closed' };
    peak = Math.max(peak, ++active);
    if (r.operation === 'emailPage') { started.resolve(); await gate.promise; }
    --active; return r.operation === 'emailPage' ? { page: { emails: [] } } : { email: { id: r.emailId } };
  });
  const page = f.client.emailPage('default', 'inbox'), body = f.client.readEmail('default', 'one');
  await started.promise; assert.equal(f.state.authorizations, 1); assert.equal(f.state.calls.length, 1);
  gate.resolve(); await Promise.all([page, body]);
  assert.equal(peak, 1); assert.equal(f.state.authorizations, 2);
  const [a, b] = f.state.calls; assert.match(a.syncSessionId, /^[0-9a-f-]{36}$/i);
  assert.equal(a.syncSessionId, b.syncSessionId);
  await f.client.closeReadSession(); assert.equal(f.state.calls.at(-1).syncSessionId, a.syncSessionId);
});

test('A failed native read retires queued reads without another login or replay and preserves the first error', async () => {
  for (const code of ['authenticationRequired', 'network']) {
    const gate = deferred(), started = deferred(); let fail = true;
    const f = imapFixture(async r => {
      if (r.operation === 'closeSyncSession') throw Error('Synthetic cleanup failure');
      if (fail) { started.resolve(); await gate.promise; return { error: code }; }
      return { email: { id: r.emailId } };
    });
    const pending = Promise.allSettled([f.client.emailPage('default', 'inbox'), f.client.readEmail('default', 'one'), f.client.readEmail('default', 'two')]);
    await started.promise; gate.resolve(); const results = await pending;
    assert.ok(results.every(r => r.status === 'rejected' && r.reason.code === code));
    assert.equal(results[0].reason, results[1].reason);
    assert.equal(f.state.authorizations, 1);
    assert.deepEqual(f.state.calls.map(r => r.operation), ['emailPage', 'closeSyncSession']);
    fail = false; await f.client.readEmail('default', 'later');
    assert.notEqual(f.state.calls[0].syncSessionId, f.state.calls.at(-1).syncSessionId);
    await f.client.closeReadSession();
  }
});

test('Lifecycle close drains accepted reads, retires queued reads, and resumes with a new lease', async () => {
  const gate = deferred(), started = deferred();
  const f = imapFixture(async r => {
    if (r.operation === 'closeSyncSession') return { state: 'closed' };
    if (r.emailId === 'one') { started.resolve(); await gate.promise; }
    return { email: { id: r.emailId } };
  });
  const accepted = f.client.readEmail('default', 'one');
  const retired = assert.rejects(f.client.readEmail('default', 'two'), { code: 'network' });
  await started.promise;
  const closing = f.client.closeReadSession(); assert.equal(f.client.closeReadSession(), closing);
  const resumed = f.client.readEmail('default', 'three');
  assert.equal(f.state.calls.length, 1); gate.resolve();
  await Promise.all([accepted, retired, closing, resumed]);
  assert.deepEqual(f.state.calls.map(r => r.operation), ['readEmail', 'closeSyncSession', 'readEmail']);
  assert.notEqual(f.state.calls[0].syncSessionId, f.state.calls[2].syncSessionId);
  await f.client.closeReadSession();
});

test('Credential rotation closes the old connection before admitting a new token', async () => {
  let token = 'old';
  const f = imapFixture(async r => r.operation === 'closeSyncSession' ? { state: 'closed' } : { email: { id: r.emailId } }, async () => token);
  await f.client.readEmail('default', 'one'); token = 'new'; await f.client.readEmail('default', 'two');
  assert.deepEqual(f.state.calls.map(r => r.operation), ['readEmail', 'closeSyncSession', 'readEmail']);
  assert.equal(f.state.calls[0].authorization, 'old'); assert.equal(f.state.calls[2].authorization, 'new');
  assert.notEqual(f.state.calls[0].syncSessionId, f.state.calls[2].syncSessionId);
  await f.client.closeReadSession();
});

test('Closing during a foreground credential wait prevents a late socket', async () => {
  const gate = deferred(), started = deferred();
  const f = imapFixture(async () => assert.fail('Cancelled read reached native'), async () => { started.resolve(); return gate.promise; });
  const retired = assert.rejects(f.client.readEmail('default', 'one'), { code: 'network' });
  await started.promise; const closed = f.client.closeReadSession(); gate.resolve('synthetic');
  await Promise.all([retired, closed]); assert.equal(f.state.calls.length, 0);
});
