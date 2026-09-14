const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JmapClient, JmapDraftError, JMAP_CORE: CORE, JMAP_MAIL: MAIL } = require('../.tools/prototype-test-output/ohosTest/ets/support/PrototypeJmapClient.js');

function draft() {
  return { from: { name: 'Sender 鸿蒙', email: 'sender@example.com' },
    to: [{ name: 'To', email: 'to@example.com' }], cc: [{ name: '', email: 'cc@example.com' }],
    bcc: [{ name: 'Private', email: 'bcc@example.com' }], replyTo: [{ name: '', email: 'reply@example.com' }],
    subject: 'Draft 📬', textBody: 'Hello 鸿蒙 📬\nSecond line',
    inReplyTo: ['parent@example.com'], references: ['root@example.com', 'parent@example.com'] };
}

function fixture() {
  const state = { readOnly: false, writes: [], calls: [], reject: null, alter: result => result,
    lose: false, status: 200, maxSizeRequest: 4 * 1024 * 1024,
    boxes: [{ id: 'd1', name: 'Not an English folder name', role: 'drafts', parentId: null,
      sortOrder: 0, totalEmails: 0, unreadEmails: 0,
      myRights: { mayAddItems: true, mayRemoveItems: true, maySetSeen: true, maySetKeywords: true } }] };
  const json = (body, status = 200) => ({ status, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const client = new JmapClient('https://mail.example/session', {
    parseUrl: value => new URL(value),
    async send(request) {
      if (request.method === 'GET') {
        return json({ capabilities: { [CORE]: { maxObjectsInGet: 50, maxSizeRequest: state.maxSizeRequest }, [MAIL]: {} },
          accounts: { personal: { name: 'Fixture', isPersonal: true, isReadOnly: state.readOnly, accountCapabilities: { [MAIL]: {} } } },
          primaryAccounts: { [MAIL]: 'personal' }, apiUrl: 'https://mail.example/api', state: 's1' });
      }
      const payload = JSON.parse(request.body);
      assert.deepEqual(payload.using, [CORE, MAIL]);
      assert.equal(payload.methodCalls.length, 1);
      const [method, args, callId] = payload.methodCalls[0];
      state.calls.push(method);
      assert.equal(args.accountId, 'personal');
      let result;
      if (method === 'Mailbox/get') { result = { state: 'm1', list: state.boxes, notFound: [] }; }
      else {
        assert.equal(method, 'Email/set');
        assert.deepEqual(Object.keys(args).sort(), ['accountId', 'create']);
        assert.deepEqual(Object.keys(args.create), ['draft']);
        state.writes.push(args.create.draft);
        if (state.lose) { throw new Error('SENSITIVE dropped after commit'); }
        if (state.status !== 200) { return json({}, state.status); }
        result = state.reject ? { oldState: 'e1', newState: 'e1', created: null, notCreated: { draft: state.reject } } :
          { oldState: 'e1', newState: 'e2', created: { draft: { id: 'new1', blobId: 'blob1', threadId: 'thread1', size: 420 } }, notCreated: null };
        result = state.alter(result);
      }
      return json({ sessionState: 's1', methodResponses: [[method, { accountId: args.accountId, ...result }, callId]] });
    }
  }, { authorization: async () => 'Bearer fixture-token' });
  return { client, state };
}

test('Draft creation preserves Unicode, recipient kinds and reply headers without submission', async () => {
  const { client, state } = fixture();
  const input = draft();
  const result = await client.createDraft('personal', input);
  assert.deepEqual(result, { id: 'new1', blobId: 'blob1', threadId: 'thread1', size: 420, state: 'e2', mailboxId: 'd1' });
  const sent = state.writes[0];
  assert.deepEqual(sent, { from: [input.from], to: input.to, cc: input.cc, bcc: input.bcc, replyTo: input.replyTo,
    subject: input.subject, inReplyTo: input.inReplyTo, references: input.references,
    textBody: [{ partId: 'body', type: 'text/plain' }], bodyValues: { body: {
      value: input.textBody, isTruncated: false, isEncodingProblem: false } },
    mailboxIds: { d1: true }, keywords: { $draft: true, $seen: true } });
  assert.deepEqual(state.calls, ['Mailbox/get', 'Email/set']);
});

test('Unfinished draft addresses and an empty body can be saved without fabricating delivery fields', async () => {
  const { client, state } = fixture();
  await client.createDraft('personal', { from: null, to: [{ name: '', email: 'unfinished' }], cc: [], bcc: [], replyTo: [],
    subject: '', textBody: '', inReplyTo: [], references: [] });
  assert.equal(state.writes[0].from, null);
  assert.deepEqual(state.writes[0].to, [{ name: '', email: 'unfinished' }]);
  assert.equal(state.writes[0].bodyValues.body.value, '');
  for (const key of ['cc', 'bcc', 'replyTo', 'inReplyTo', 'references']) { assert.equal(state.writes[0][key], null); }
});

test('Draft upload snapshots input before asynchronous discovery and folder lookup', async () => {
  const { client, state } = fixture();
  const input = draft(); const expected = structuredClone(input);
  const save = client.createDraft('personal', input);
  input.from.name = 'Edited'; input.to[0].email = 'different@example.com'; input.references.push('later@example.com');
  input.subject = 'Changed'; input.textBody = 'Changed';
  await save;
  assert.equal(state.writes[0].from[0].name, expected.from.name);
  assert.deepEqual(state.writes[0].to, expected.to);
  assert.deepEqual(state.writes[0].references, expected.references);
  assert.equal(state.writes[0].subject, expected.subject);
  assert.equal(state.writes[0].bodyValues.body.value, expected.textBody);
});

test('Missing or ambiguous Drafts roles, account scope and permissions prevent creation', async () => {
  for (const [change, code] of [
    [s => s.readOnly = true, 'accountReadOnly'], [s => s.boxes = [], 'draftsUnavailable'],
    [s => s.boxes.push({ ...s.boxes[0], id: 'd2' }), 'draftsUnavailable'],
    [s => s.boxes[0].role = null, 'draftsUnavailable'],
    [s => s.boxes[0].myRights.mayAddItems = false, 'forbidden']
  ]) {
    const { client, state } = fixture(); change(state);
    await assert.rejects(client.createDraft('personal', draft()), { code });
    assert.equal(state.writes.length, 0);
  }
  const { client, state } = fixture();
  await assert.rejects(client.createDraft('other', draft()), { code: 'accountNotFound' });
  assert.equal(state.writes.length, 0);
});

test('Invalid draft structure, header controls and UTF-8 body limits fail before network writes', async () => {
  for (const alter of [d => d.subject = 'x\r\nBcc: someone@example.com', d => d.to[0].email = 'x\ny',
    d => d.from.name = 'x\u0000y', d => d.references = ['<bad@example.com>'], d => d.to = null,
    d => d.textBody = 'x\u0000y']) {
    const { client, state } = fixture(); const input = draft(); alter(input);
    await assert.rejects(client.createDraft('personal', input), { code: 'invalidDraft' });
    assert.equal(state.calls.length, 0);
  }
  const { client, state } = fixture(); const input = draft(); input.textBody = '📬'.repeat(65537);
  await assert.rejects(client.createDraft('personal', input), { code: 'draftTooLarge' });
  assert.equal(state.calls.length, 0);
});

test('Server request limit counts UTF-8 and escaped JSON bytes before creation', async () => {
  for (const body of ['鸿'.repeat(700), '\n'.repeat(1000)]) {
    const { client, state } = fixture(); state.maxSizeRequest = 2000;
    const input = draft(); input.textBody = body;
    await assert.rejects(client.createDraft('personal', input), { code: 'requestTooLarge' });
    assert.deepEqual(state.calls, ['Mailbox/get']);
  }
});

test('Explicit creation rejections remain distinguishable from uncertain outcomes and omit server text', async () => {
  for (const [type, code] of [['forbidden', 'forbidden'], ['overQuota', 'overQuota'], ['tooLarge', 'draftTooLarge'],
    ['invalidProperties', 'invalidDraft'], ['unknown-secret-type', 'draftRejected']]) {
    const { client, state } = fixture(); state.reject = { type, description: 'SENSITIVE', properties: ['SENSITIVE'] };
    await assert.rejects(client.createDraft('personal', draft()), error => {
      assert.ok(error instanceof JmapDraftError); assert.equal(error.code, code); assert.equal(error.mayHaveCreated, false);
      assert.ok(!String(error).includes('SENSITIVE')); return true;
    });
    assert.equal(state.writes.length, 1);
  }
});

test('Lost responses, redirects and malformed or contradictory acknowledgements never replay creation', async () => {
  for (const change of [s => s.lose = true, s => s.status = 307, s => s.status = 500,
    s => s.alter = r => ({ ...r, notCreated: { draft: { type: 'forbidden' } } }),
    s => s.alter = r => ({ ...r, created: null }),
    s => s.alter = r => ({ ...r, updated: { unrelated: null } }),
    s => s.alter = r => ({ ...r, destroyed: ['old'] }),
    s => s.alter = r => ({ ...r, created: { other: r.created.draft } }),
    s => s.alter = r => ({ ...r, created: { draft: { id: 'new1' } } })]) {
    const { client, state } = fixture(); change(state);
    await assert.rejects(client.createDraft('personal', draft()), error => {
      assert.ok(error instanceof JmapDraftError); assert.equal(error.code, 'draftOutcomeUnknown');
      assert.equal(error.mayHaveCreated, true); assert.ok(!String(error).includes('SENSITIVE')); return true;
    });
    assert.equal(state.writes.length, 1);
  }
});
