const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JmapClient, JmapError, JMAP_CORE, JMAP_MAIL, MAX_RESPONSE_BYTES, canSetKeyword } = require('../.tools/prototype-test-output/ohosTest/ets/support/PrototypeJmapClient.js');

function session() {
  return { capabilities: { [JMAP_CORE]: { maxObjectsInGet: 2 }, [JMAP_MAIL]: {} },
    accounts: {
      shared: { name: 'Shared', isPersonal: false, isReadOnly: true, accountCapabilities: { [JMAP_MAIL]: {} } },
      personal: { name: 'Personal', isPersonal: true, isReadOnly: false, accountCapabilities: { [JMAP_MAIL]: {} } }
    }, primaryAccounts: { [JMAP_MAIL]: 'personal' }, state: 'session-1', apiUrl: 'https://mail.example/api' };
}

function email(id = 'e1') {
  return { id, threadId: 't1', messageId: ['internet-id@example.com'],
    mailboxIds: { inbox: true, label: true }, keywords: { $seen: true, $flagged: true },
    from: [{ name: 'Alex', email: 'alex@example.com' }], to: null,
    replyTo: [{ name: null, email: 'reply@example.com' }], subject: 'Hello', preview: 'A preview only',
    receivedAt: '2026-09-13T00:00:00Z', hasAttachment: false,
    textBody: [{ partId: 'part1', type: 'text/plain' }, { partId: 'image', type: 'image/png' }],
    htmlBody: [{ partId: 'html', type: 'text/html' }],
    bodyValues: { part1: { value: 'Full plain text', isTruncated: false, isEncodingProblem: false } } };
}

function json(body, status = 200) { return { status, headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(body) }; }
function setup(handler, sessionValue = session()) {
  const requests = [];
  const transport = {
    parseUrl: (value, base) => new URL(value, base),
    async send(request) {
      requests.push(request);
      if (request.method === 'GET') { return json(sessionValue); }
      const payload = JSON.parse(request.body);
      assert.deepEqual(payload.using, [JMAP_CORE, JMAP_MAIL]);
      const [name, args, callId] = payload.methodCalls[0];
      const answer = await handler(name, args, callId);
      if (answer.status) { return answer; }
      return json({ sessionState: 'session-1', methodResponses: [[name, { accountId: args.accountId, ...answer }, callId]] });
    }
  };
  const client = new JmapClient('https://mail.example/.well-known/jmap', transport,
    { authorization: async () => 'Bearer fixture-token' });
  return { client, requests, transport };
}

const rejects = (promise, code) => assert.rejects(promise, error => error instanceof JmapError && error.code === code);

test('JMAP session preserves primary versus shared accounts, coalesces discovery, and isolates returned data', async () => {
  const { client, requests } = setup(() => assert.fail('unexpected API call'));
  const [a, b] = await Promise.all([client.connect(), client.connect()]);
  assert.equal(a.primaryAccountId, 'personal');
  assert.equal(a.accounts[0].isReadOnly, true);
  a.accounts[1].id = 'tampered'; a.apiUrl = 'https://evil.example/';
  assert.equal(b.accounts[1].id, 'personal');
  assert.equal((await client.connect()).apiUrl, 'https://mail.example/api');
  assert.equal(requests.length, 1);
});

test('JMAP keyword patches preserve unrelated flags and membership and remove with null', async () => {
  const stored = email(); stored.keywords['custom-label'] = true;
  const { client, requests } = setup((name, args) => {
    if (name === 'Email/get') { return { state: 'next', list: [stored], notFound: [] }; }
    assert.equal(name, 'Email/set');
    assert.deepEqual(Object.keys(args).sort(), ['accountId', 'update']);
    assert.deepEqual(Object.keys(args.update), ['e1']);
    const patch = args.update.e1;
    assert.equal(Object.keys(patch).length, 1);
    for (const [path, value] of Object.entries(patch)) {
      assert.match(path, /^keywords\/\$(seen|flagged)$/);
      const key = path.slice('keywords/'.length);
      if (value === null) { delete stored.keywords[key]; } else { assert.equal(value, true); stored.keywords[key] = value; }
    }
    return { oldState: 'old', newState: 'next', updated: { e1: null }, notUpdated: null };
  });
  assert.equal(await client.setKeyword('personal', 'e1', '$flagged', false), 'next');
  assert.deepEqual(JSON.parse(requests[1].body).methodCalls[0][1].update, { e1: { 'keywords/$flagged': null } });
  await client.setKeyword('personal', 'e1', '$seen', false);
  await client.setKeyword('personal', 'e1', '$flagged', true);
  const result = await client.readEmail('personal', 'e1');
  assert.deepEqual(result.mailboxIds, ['inbox', 'label']);
  assert.deepEqual(result.keywords, ['custom-label', '$flagged']);
});

test('JMAP refuses read-only accounts and unsupported keyword writes before POST', async () => {
  const { client, requests } = setup(() => assert.fail('write must not be sent'));
  await rejects(client.setKeyword('shared', 'e1', '$seen', true), 'accountReadOnly');
  await rejects(client.setKeyword('outsider', 'e1', '$seen', true), 'accountNotFound');
  await rejects(client.setKeyword('personal', 'e1', '$draft', true), 'invalidArgument');
  await rejects(client.setKeyword('personal', 'e1', '$seen', 'true'), 'invalidArgument');
  assert.equal(requests.length, 1);
});

test('JMAP requires keyword permission in every mailbox, independently for seen and stars', () => {
  const mail = { mailboxIds: ['inbox', 'label'] };
  const boxes = [{ id: 'inbox', maySetSeen: true, maySetKeywords: true },
    { id: 'label', maySetSeen: true, maySetKeywords: false }];
  assert.equal(canSetKeyword(mail, boxes, '$seen'), true);
  assert.equal(canSetKeyword(mail, boxes, '$flagged'), false);
  assert.equal(canSetKeyword(mail, boxes.slice(0, 1), '$seen'), false);
  assert.equal(canSetKeyword({ mailboxIds: [] }, boxes, '$seen'), false);
});

test('JMAP surfaces per-message write rejection and sanitizes server descriptions', async () => {
  for (const [type, expected] of [['forbidden', 'forbidden'], ['notFound', 'messageNotFound'],
    ['tooManyKeywords', 'updateRejected'], ['private-server-error', 'updateRejected']]) {
    const { client } = setup(() => ({ oldState: null, newState: 'unchanged', updated: null,
      notUpdated: { e1: { type, description: 'secret message contents' } } }));
    await rejects(client.setKeyword('personal', 'e1', '$flagged', true), expected);
  }
});

test('JMAP refuses contradictory, missing and malformed mutation acknowledgements', async () => {
  for (const change of [
    { updated: {} }, { updated: { foreign: null } }, { notUpdated: { e1: { type: 'forbidden' } } },
    { newState: 5 }, { updated: { e1: true } }, { destroyed: ['e1'] }, { created: { x: { id: 'x' } } }
  ]) {
    const { client } = setup(() => ({ oldState: 'old', newState: 'next', updated: { e1: null }, notUpdated: null, ...change }));
    await rejects(client.setKeyword('personal', 'e1', '$seen', true), 'invalidResponse');
  }
  const { client } = setup(() => ({ oldState: 'old', newState: 'next', updated: { e1: { keywords: { $seen: true } } }, notUpdated: null }));
  assert.equal(await client.setKeyword('personal', 'e1', '$seen', true), 'next');
});

test('JMAP never automatically retries a write after transport loss or a redirect', async () => {
  for (const fail of [() => { throw new Error('socket lost after server applied write'); },
    () => ({ status: 307, headers: { location: '/api-2' }, body: '' })]) {
    const { client, requests } = setup(fail);
    await assert.rejects(client.setKeyword('personal', 'e1', '$seen', true), JmapError);
    assert.equal(requests.filter(request => request.method === 'POST').length, 1);
  }
});

test('JMAP lists role-based mailboxes and rejects accounts outside the session', async () => {
  const { client, requests } = setup((name, args) => {
    assert.equal(name, 'Mailbox/get'); assert.equal(args.accountId, 'personal');
    return { state: 'm1', notFound: [], list: [{ id: 'inbox', name: 'Boîte de réception', parentId: null,
      role: 'inbox', sortOrder: 0, totalEmails: 2, unreadEmails: 1,
      myRights: { maySetSeen: true, maySetKeywords: false, mayAddItems: true, mayRemoveItems: true } }] };
  });
  assert.equal((await client.mailboxes('personal'))[0].role, 'inbox');
  await rejects(client.mailboxes('outsider'), 'accountNotFound');
  assert.equal(requests.length, 2);
});

test('JMAP paging respects server limits, restores query order, preserves membership and missing messages', async () => {
  let page = 0;
  const { client } = setup((name, args) => {
    if (name === 'Email/query') {
      assert.equal(args.limit, 2); assert.equal(args.filter.inMailbox, 'inbox');
      page = args.position;
      return { queryState: 'q1', position: page, total: 3, ids: page === 0 ? ['e2', 'e1'] : ['gone'] };
    }
    assert.equal(name, 'Email/get');
    assert.equal(args.fetchTextBodyValues, undefined);
    return { state: 'e1', list: page === 0 ? [email('e1'), email('e2')] : [], notFound: page === 0 ? [] : ['gone'] };
  });
  const first = await client.emailPage('personal', 'inbox');
  assert.deepEqual(first.emails.map(e => e.id), ['e2', 'e1']);
  assert.deepEqual(first.emails[0].mailboxIds, ['inbox', 'label']);
  assert.equal(first.emails[0].textBody, null);
  assert.equal(first.nextPosition, 2);
  const last = await client.emailPage('personal', 'inbox', first.nextPosition, first.queryState);
  assert.deepEqual(last.notFound, ['gone']); assert.equal(last.nextPosition, null);
});

test('JMAP does not lose pages when server returns fewer IDs than requested without total', async () => {
  const { client } = setup(name => name === 'Email/query' ?
    { queryState: 'q', position: 0, ids: ['e1'] } : { state: 'e', list: [email()], notFound: [] });
  assert.equal((await client.emailPage('personal', 'inbox')).nextPosition, 1);
});

test('JMAP detects changed query state before appending a page or fetching its messages', async () => {
  const { client, requests } = setup(() => ({ queryState: 'new', position: 2, ids: ['e1'] }));
  await rejects(client.emailPage('personal', 'inbox', 2, 'old'), 'queryChanged');
  assert.equal(requests.length, 2);
});

test('JMAP empty inbox avoids Email/get', async () => {
  const { client, requests } = setup(() => ({ queryState: 'q', position: 0, ids: [], total: 0 }));
  const page = await client.emailPage('personal', 'inbox');
  assert.deepEqual(page.emails, []); assert.equal(page.nextPosition, null); assert.equal(requests.length, 2);
});

test('JMAP reader preserves reply-to, RFC message ID, body truncation and encoding status', async () => {
  const message = email();
  message.bodyValues.part1.isTruncated = true; message.bodyValues.part1.isEncodingProblem = true;
  const { client } = setup((name, args) => {
    assert.equal(name, 'Email/get'); assert.equal(args.fetchTextBodyValues, true);
    assert.equal(args.maxBodyValueBytes, 262144);
    return { state: 'e', list: [message], notFound: [] };
  });
  const result = await client.readEmail('personal', 'e1');
  assert.equal(result.textBody, 'Full plain text');
  assert.equal(result.bodyTruncated, true); assert.equal(result.bodyEncodingProblem, true);
  assert.equal(result.replyTo[0].email, 'reply@example.com');
  assert.deepEqual(result.messageIds, ['internet-id@example.com']);
});

test('JMAP HTML-only content is not presented as complete plain text', async () => {
  const message = email(); message.textBody = []; message.bodyValues = {};
  const { client } = setup(() => ({ state: 'e', list: [message], notFound: [] }));
  const result = await client.readEmail('personal', 'e1');
  assert.equal(result.textBody, null); assert.equal(result.hasHtmlBody, true);
});

test('JMAP accepts fractional UTC timestamps and rejects normalized impossible dates', async () => {
  const value = email(); value.receivedAt = '2026-09-13T00:00:00.125Z';
  const { client } = setup(() => ({ state: 'e', list: [value], notFound: [] }));
  assert.equal((await client.readEmail('personal', 'e1')).receivedAt, Date.parse(value.receivedAt));
  value.receivedAt = '2026-02-30T00:00:00Z';
  await rejects(client.readEmail('personal', 'e1'), 'invalidResponse');
});

test('JMAP refuses to declare an inbox complete when total contradicts an empty page', async () => {
  const { client } = setup(() => ({ queryState: 'q', position: 0, ids: [], total: 5 }));
  await rejects(client.emailPage('personal', 'inbox'), 'invalidResponse');
});

test('JMAP rejects duplicate, foreign, unaccounted, and wrongly typed Email/get results', async () => {
  for (const list of [[email(), email()], [email('foreign')], [], [{ ...email(), keywords: { $seen: false } }]]) {
    const { client } = setup(() => ({ state: 'e', list, notFound: [] }));
    await rejects(client.readEmail('personal', 'e1'), 'invalidResponse');
  }
  const { client } = setup(() => ({ state: 'e', list: [], notFound: ['e1'] }));
  assert.equal(await client.readEmail('personal', 'e1'), null);
});

test('JMAP validates invocation name, correlation ID, account and method-level errors', async () => {
  for (const change of [
    (n, a, c) => ['Other/get', { accountId: a.accountId }, c],
    (n, a, c) => [n, { accountId: 'shared' }, c],
    (n, a) => [n, { accountId: a.accountId }, 'wrong']
  ]) {
    const { client } = setup((n, a, c) => json({ sessionState: 's', methodResponses: [change(n, a, c)] }));
    await rejects(client.mailboxes('personal'), 'invalidResponse');
  }
  const { client } = setup((n, a, c) => json({ sessionState: 's', methodResponses:
    [['error', { type: 'tooManyObjects', description: 'private mail content' }, c]] }));
  await rejects(client.mailboxes('personal'), 'tooManyObjects');
});

test('JMAP rejects insecure endpoints, embedded credentials, and untrusted API origins before forwarding auth', async () => {
  const { transport } = setup(() => {});
  for (const endpoint of ['http://mail.example', 'https://user:pass@mail.example', 'https://mail.example/#x', 'https://mail.example/\r\n']) {
    assert.throws(() => new JmapClient(endpoint, transport, { authorization: async () => 'Bearer test' }), { code: 'unsafeEndpoint' });
  }
  const raw = session(); raw.apiUrl = 'https://untrusted.example/api';
  const { client, requests } = setup(() => assert.fail('must not forward auth'), raw);
  await rejects(client.connect(), 'untrustedApiOrigin'); assert.equal(requests.length, 1);
});

test('JMAP follows only bounded same-origin HTTPS discovery redirects and never replays POST', async () => {
  const { client, transport, requests } = setup(() => ({ status: 307, headers: { location: '/elsewhere' }, body: '' }));
  const send = transport.send;
  let first = true;
  transport.send = async req => {
    if (first) { first = false; return { status: 302, headers: { Location: '/session' }, body: '' }; }
    return send(req);
  };
  await client.connect(); assert.equal(requests[0].url, 'https://mail.example/session');
  await rejects(client.mailboxes('personal'), 'redirectRejected');
  for (const location of ['https://evil.example/', 'http://mail.example/', '/loop']) {
    const { client: redirected, transport: wire } = setup(() => {});
    let count = 0;
    wire.send = async () => { count++; return { status: 302, headers: { location }, body: '' }; };
    await assert.rejects(redirected.connect(), JmapError);
    assert.ok(count <= 4);
  }
});

test('JMAP sanitizes transport errors and classifies HTTP failures without returning server bodies', async () => {
  for (const [status, code] of [[401, 'authenticationRequired'], [403, 'authenticationRequired'], [429, 'rateLimited'], [500, 'http']]) {
    const { client, transport } = setup(() => {});
    transport.send = async () => ({ status, headers: {}, body: 'secret-token' });
    await rejects(client.connect(), code);
  }
  const { client, transport } = setup(() => {});
  transport.send = async () => { throw new Error('secret-token'); };
  await assert.rejects(client.connect(), e => e.message === 'JMAP: network');
});

test('JMAP rejects malformed, oversized and non-JSON discovery responses, then permits a clean retry', async () => {
  for (const bad of [
    { status: 200, headers: { 'content-type': 'text/html' }, body: '<html>login</html>' },
    { status: 200, headers: { 'content-type': 'application/json' }, body: '{' },
    { status: 200, headers: { 'content-type': 'application/json' }, body: ' '.repeat(MAX_RESPONSE_BYTES + 1) },
    json({ ...session(), primaryAccounts: { [JMAP_MAIL]: 'absent' } })
  ]) {
    const { client, transport } = setup(() => {});
    const send = transport.send;
    transport.send = async () => bad;
    await assert.rejects(client.connect(), JmapError);
    transport.send = send;
    assert.equal((await client.connect()).primaryAccountId, 'personal');
  }
});

test('JMAP empty or injected credentials never reach the transport', async () => {
  for (const auth of ['', 'Bearer token\r\nX-Leak: yes']) {
    const { transport, requests } = setup(() => {});
    const client = new JmapClient('https://mail.example/jmap', transport, { authorization: async () => auth });
    await rejects(client.connect(), 'authenticationRequired'); assert.equal(requests.length, 0);
  }
});
