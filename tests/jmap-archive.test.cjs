const { test } = require('node:test');
const assert = require('node:assert/strict');
const { JmapClient, JMAP_CORE: CORE, JMAP_MAIL: MAIL } = require('../.tools/prototype-test-output/ohosTest/ets/support/PrototypeJmapClient.js');

function fixture() {
  const state = { version: 1, writes: [], race: false, lose: false, readOnly: false,
    mail: { id: 'e1', threadId: 't1', messageId: null, mailboxIds: { inbox: true, label: true },
      keywords: { $flagged: true }, from: null, to: null, replyTo: null, subject: 'Archive test',
      preview: '', receivedAt: '2026-09-13T00:00:00Z', hasAttachment: false },
    boxes: ['inbox', 'archive', 'label'].map((id, index) => ({ id, name: `Localized ${id}`, role: index < 2 ? id : null,
      parentId: null, sortOrder: index, totalEmails: 1, unreadEmails: 1,
      myRights: { maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true } })) };
  const json = body => ({ status: 200, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const client = new JmapClient('https://mail.example/session', {
    parseUrl: value => new URL(value),
    async send(request) {
      if (request.method === 'GET') {
        return json({ capabilities: { [CORE]: { maxObjectsInGet: 20 }, [MAIL]: {} },
          accounts: { personal: { name: 'Fixture', isPersonal: true, isReadOnly: state.readOnly, accountCapabilities: { [MAIL]: {} } } },
          primaryAccounts: { [MAIL]: 'personal' }, state: 'session', apiUrl: 'https://mail.example/api' });
      }
      const [method, args, callId] = JSON.parse(request.body).methodCalls[0];
      let result;
      if (method === 'Mailbox/get') { result = { state: 'boxes', list: state.boxes, notFound: [] }; }
      else if (method === 'Email/get') { result = { state: String(state.version), list: state.mail ? [state.mail] : [], notFound: state.mail ? [] : ['e1'] }; }
      else {
        assert.equal(method, 'Email/set');
        state.writes.push(args);
        assert.deepEqual(Object.keys(args).sort(), ['accountId', 'ifInState', 'update']);
        if (state.race) { state.race = false; state.version++; }
        if (args.ifInState !== String(state.version)) {
          return json({ sessionState: 'session', methodResponses: [['error', { type: 'stateMismatch' }, callId]] });
        }
        for (const [path, value] of Object.entries(args.update.e1)) {
          assert.match(path, /^mailboxIds\/(inbox|archive)$/);
          const id = path.slice('mailboxIds/'.length);
          if (value === null) { delete state.mail.mailboxIds[id]; } else { assert.equal(value, true); state.mail.mailboxIds[id] = true; }
        }
        result = { oldState: String(state.version++), newState: String(state.version), updated: { e1: null }, notUpdated: null };
        if (state.lose) { throw new Error('lost acknowledgement'); }
      }
      return json({ sessionState: 'session', methodResponses: [[method, { accountId: args.accountId, ...result }, callId]] });
    }
  }, { authorization: async () => 'Bearer fixture-token' });
  return { client, state };
}

test('Archive and undo preserve labels and concurrent keyword changes, using mailbox roles', async () => {
  const { client, state } = fixture();
  const undo = await client.archiveEmail('personal', 'e1');
  assert.deepEqual(state.mail.mailboxIds, { label: true, archive: true });
  assert.deepEqual(state.writes[0].update.e1, { 'mailboxIds/inbox': null, 'mailboxIds/archive': true });
  state.mail.keywords.$seen = true; state.version++;
  await client.undoArchive(undo);
  assert.deepEqual(state.mail.mailboxIds, { label: true, inbox: true });
  assert.deepEqual(state.mail.keywords, { $flagged: true, $seen: true });
  assert.equal(state.writes[1].ifInState, '3');
});

test('Undo does not remove Archive membership that existed before the action', async () => {
  const { client, state } = fixture();
  state.mail.mailboxIds.archive = true;
  state.boxes[1].myRights.mayAddItems = false;
  state.boxes[1].myRights.mayRemoveItems = false;
  const undo = await client.archiveEmail('personal', 'e1');
  assert.equal(undo.addedArchive, false);
  assert.deepEqual(state.writes[0].update.e1, { 'mailboxIds/inbox': null });
  await client.undoArchive(undo);
  assert.deepEqual(state.writes[1].update.e1, { 'mailboxIds/inbox': true });
  assert.equal(state.mail.mailboxIds.archive, true);
});

test('Archive refuses missing roles, ambiguous roles and denied move permissions without writing', async () => {
  for (const alter of [s => s.boxes[1].role = null, s => s.boxes[2].role = 'archive',
    s => s.boxes[0].myRights.mayRemoveItems = false, s => s.boxes[1].myRights.mayAddItems = false,
    s => delete s.mail.mailboxIds.inbox]) {
    const { client, state } = fixture(); alter(state);
    await assert.rejects(client.archiveEmail('personal', 'e1'), { code: 'archiveUnavailable' });
    assert.equal(state.writes.length, 0);
  }
  const { client, state } = fixture(); state.readOnly = true;
  await assert.rejects(client.archiveEmail('personal', 'e1'), { code: 'accountReadOnly' });
  assert.equal(state.writes.length, 0);
});

test('Undo refuses later mailbox moves and revoked permissions without writing', async () => {
  for (const [alter, code] of [[s => { s.mail.mailboxIds.later = true; }, 'stateMismatch'],
    [s => { s.boxes[0].myRights.mayAddItems = false; }, 'forbidden'],
    [s => { s.boxes[1].myRights.mayRemoveItems = false; }, 'forbidden'],
    [s => { s.mail = null; }, 'messageNotFound']]) {
    const { client, state } = fixture();
    const undo = await client.archiveEmail('personal', 'e1'); alter(state);
    await assert.rejects(client.undoArchive(undo), { code });
    assert.equal(state.writes.length, 1);
  }
});

test('Archive and undo use an atomic state precondition and never retry a race', async () => {
  const first = fixture(); first.state.race = true;
  await assert.rejects(first.client.archiveEmail('personal', 'e1'), { code: 'stateMismatch' });
  assert.deepEqual(first.state.mail.mailboxIds, { inbox: true, label: true });
  assert.equal(first.state.writes.length, 1);
  const { client, state } = fixture(); const undo = await client.archiveEmail('personal', 'e1'); state.race = true;
  await assert.rejects(client.undoArchive(undo), { code: 'stateMismatch' });
  assert.deepEqual(state.mail.mailboxIds, { archive: true, label: true });
  assert.equal(state.writes.length, 2);
});

test('A lost archive acknowledgement never produces an undo receipt or replays the write', async () => {
  const { client, state } = fixture(); state.lose = true;
  await assert.rejects(client.archiveEmail('personal', 'e1'), { code: 'network' });
  assert.equal(state.writes.length, 1);
  assert.deepEqual(state.mail.mailboxIds, { label: true, archive: true });
});
