// MPL-2.0: https://mozilla.org/MPL/2.0/
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
function load(file, dependencies, globals = {}) {
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('require', 'module', 'exports', ...Object.keys(globals), source)(name => {
    if (name === '@kit.ArkTS' && !(name in dependencies)) return { util: { generateRandomUUID: () => require('node:crypto').randomUUID() } };
    assert.ok(name in dependencies, `Unexpected dependency: ${name}`); return dependencies[name];
  }, module, module.exports, ...Object.values(globals));
  return module.exports;
}
const jmap = load('harmony/entry/src/main/ets/mail/jmap/JmapClient.ts', {});
const receipt = () => ({ accountId: 'default', emailId: 'inbox_uid', inboxId: 'inbox', archiveId: 'archive',
  addedArchive: true, expectedMailboxIds: ['archive'], movedEmailId: 'archive_uid', canUndo: true, imap: true });
function imap(respond, credentials = { authorization: async () => 'Basic synthetic' }) {
  const calls = [];
  const { NativeImapClient } = load('harmony/entry/src/main/ets/mail/imap/NativeImapClient.ets', {
    '../jmap/JmapClient': jmap,
    'libthunderbird.so': { imapAccountRequest: async raw => { const request = JSON.parse(raw); calls.push(request); return JSON.stringify(await respond(request)); } }
  });
  return { client: new NativeImapClient('imaps://synthetic.test', credentials, 'synthetic-user'), calls };
}
function operations(respond) {
  const records = { network: [], membership: [], moved: [], begun: [], ended: [], revision: 0 };
  const { MailOperations: ops } = load('harmony/entry/src/main/ets/mail/MailOperations.ets', {
    './jmap/JmapClient': jmap, '@kit.ArkTS': { util: { generateRandomUUID: () => 'synthetic-uuid' } }
  }, { AppStorage: { get: () => records.revision, setOrCreate: (_key, value) => { records.revision = value; } } });
  const mail = { id: 'inbox_uid', mailboxIds: ['inbox'], keywords: [], textBody: 'Saved text', attachments: [{ id: 'part' }] };
  const store = { mail: {
    beginMutation: async (account, id) => { records.begun.push([account, id]); return true; },
    endMutation: (account, id) => { records.ended.push([account, id]); },
    updateMailboxes: async (...args) => { records.membership.push(args); },
    moveEmailIdentity: async (...args) => { records.moved.push(args); }
  } };
  const client = {
    archiveEmail: async (...args) => { records.network.push(['archive', ...args]); return respond(false); },
    undoArchive: async (...args) => { records.network.push(['undo', ...args]); return respond(true); }
  };
  return { ops, store, client, mail, records };
}

test('IMAP archive forwards one source identity and returns a verified move receipt', async () => {
  const f = imap(async () => ({ archive: receipt() }));
  assert.deepEqual(await f.client.archiveEmail('default', 'inbox_uid'), receipt());
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0], { operation: 'archiveEmail', sessionUrl: 'imaps://synthetic.test', authorization: 'Basic synthetic',
    accountId: 'default', emailId: 'inbox_uid', username: 'synthetic-user' });
});

test('IMAP move errors and malformed receipts never retry or create an undo', async () => {
  for (const reply of [{ error: 'changeUnconfirmed' }, { archive: { ...receipt(), emailId: 'other' } },
    { archive: { ...receipt(), movedEmailId: undefined } }, { archive: { ...receipt(), expectedMailboxIds: ['wrong'] } }]) {
    const f = imap(async () => reply);
    await assert.rejects(f.client.archiveEmail('default', 'inbox_uid'), { code: 'changeUnconfirmed' });
    assert.equal(f.calls.length, 1);
  }
});

test('IMAP undo uses the current Archive UID and snapshots identity before credential await', async () => {
  let resume;
  const wait = new Promise(resolve => { resume = resolve; });
  const f = imap(async () => ({ state: 'moved', movedEmailId: 'new_inbox_uid' }), { authorization: async () => { await wait; return 'Basic synthetic'; } });
  const undo = { ...receipt(), emailId: 'archive_uid' };
  const result = f.client.undoArchive(undo);
  undo.accountId = 'different'; undo.emailId = 'different'; undo.inboxId = 'different';
  resume(); assert.equal(await result, 'new_inbox_uid');
  assert.equal(f.calls[0].accountId, 'default'); assert.equal(f.calls[0].emailId, 'archive_uid'); assert.equal(f.calls[0].mailboxId, 'inbox');
});

test('Archive projects immediately and migrates a confirmed UID under the captured local account', async () => {
  let finish;
  const gate = new Promise(resolve => { finish = resolve; });
  const f = operations(async () => { await gate; return receipt(); });
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']);
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']);
  assert.deepEqual(f.ops.overlay('local-account', f.mail).mailboxIds, ['archive']);
  assert.deepEqual(f.ops.overlay('other-account', f.mail).mailboxIds, ['inbox']);
  finish(); await f.ops.whenIdle();
  assert.equal(f.records.network.length, 1);
  assert.deepEqual(f.records.moved, [['local-account', 'inbox_uid', 'archive_uid', ['archive']]]);
  assert.equal(f.ops.undo('local-account').emailId, 'archive_uid');
  assert.equal(f.ops.currentEmailId('local-account','inbox_uid'),'archive_uid');
  assert.equal(f.ops.currentEmailId('different-account','inbox_uid'),'inbox_uid');
  assert.equal(f.ops.notice('local-account'), 'message_archived');
  assert.deepEqual(f.records.ended, [['local-account', 'inbox_uid']]);
});

test('Undo migrates its new Inbox UID without pretending the pre-archive UID is valid again', async () => {
  const f = operations(async undo => undo ? 'new_inbox_uid' : receipt());
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']); await f.ops.whenIdle();
  const undo = f.ops.undo('local-account'), archived = { ...f.mail, id: 'archive_uid', mailboxIds: ['archive'] };
  f.ops.move(f.store, f.client, 'local-account', 'default', archived, ['inbox'], undo); await f.ops.whenIdle();
  assert.deepEqual(f.records.moved[1], ['local-account', 'archive_uid', 'new_inbox_uid', ['inbox']]);
  assert.equal(f.ops.undo('local-account'), null); assert.equal(f.ops.notice('local-account'), 'archive_undone');
  assert.equal(f.ops.currentEmailId('local-account','inbox_uid'),'new_inbox_uid');
  assert.equal(f.ops.currentEmailId('local-account','archive_uid'),'new_inbox_uid');
});

test('Tagged success without COPYUID keeps an explicit local-only copy and offers no unsafe Undo', async () => {
  const f = operations(async () => ({ ...receipt(), movedEmailId: undefined, canUndo: false }));
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']); await f.ops.whenIdle();
  assert.deepEqual(f.records.moved, [['local-account', 'inbox_uid', 'local_archive_synthetic-uuid', ['archive']]]);
  assert.equal(f.ops.undo('local-account'), null);
  const boxes = [{ id: 'inbox', role: 'inbox', mayRemoveItems: true }, { id: 'archive', role: 'archive', mayAddItems: true }];
  assert.equal(jmap.archiveTarget({ ...f.mail, id: 'local_archive_synthetic-uuid' }, boxes), null);
});

test('Unconfirmed move does not migrate cache identity, offer Undo, or replay the command', async () => {
  const f = operations(async () => { throw new jmap.JmapError('changeUnconfirmed'); });
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']); await f.ops.whenIdle();
  assert.equal(f.records.network.length, 1); assert.deepEqual(f.records.moved, []);
  assert.equal(f.ops.undo('local-account'), null); assert.equal(f.ops.notice('local-account'), 'change_unconfirmed');
});

test('JMAP archive still changes membership without inventing a protocol identity', async () => {
  const f = operations(async () => ({ ...receipt(), imap: undefined, canUndo: undefined, movedEmailId: undefined }));
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['archive']); await f.ops.whenIdle();
  assert.deepEqual(f.records.membership, [['local-account', 'inbox_uid', ['archive']]]);
  assert.deepEqual(f.records.moved, []); assert.equal(f.ops.undo('local-account').emailId, 'inbox_uid');
});


test('A failed cache migration cannot redirect an open reader to an unowned destination', async () => {
  const f=operations(async()=>receipt());
  f.store.mail.moveEmailIdentity=async()=>{throw new Error('Synthetic storage failure');};
  f.ops.move(f.store,f.client,'local-account','default',f.mail,['archive']);await f.ops.whenIdle();
  assert.equal(f.ops.currentEmailId('local-account','inbox_uid'),'inbox_uid');
  assert.equal(f.ops.undo('local-account'),null);
});

test('Confirmed reader identity bookkeeping stays bounded and never crosses accounts', async () => {
  let serial=0;
  const f=operations(async()=>({...receipt(),movedEmailId:'mapped_'+serial,canUndo:true}));
  for(serial=0;serial<140;serial++) {
    f.ops.move(f.store,f.client,'local-account','default',{...f.mail,id:'source_'+serial},['archive']);
    await f.ops.whenIdle();
  }
  assert.equal(f.ops.currentEmailId('local-account','source_0'),'source_0');
  assert.equal(f.ops.currentEmailId('local-account','source_139'),'mapped_139');
  assert.equal(f.ops.currentEmailId('other-account','source_139'),'source_139');
});

function archiveBox(overrides = {}) {
  return { id: 'archive', name: 'Archive', parentId: null, role: 'archive', sortOrder: 2,
    totalEmails: 0, unreadEmails: 0, countsKnown: false, maySetSeen: true, maySetKeywords: true,
    mayAddItems: true, mayRemoveItems: true, ...overrides };
}
test('Missing Archive is an explicit creation target, never a phantom listed folder', () => {
  const inbox = archiveBox({ id: 'inbox', name: 'Inbox', role: 'inbox',
    archiveDestinationId: 'prospective', archiveDestinationName: 'INBOX.Archive' });
  const boxes = [inbox], mail = { id: 'inbox_uid', mailboxIds: ['inbox'] };
  assert.equal(jmap.archiveTarget(mail, boxes).id, 'prospective');
  assert.deepEqual(boxes, [inbox]);
  assert.equal(jmap.archiveTarget(mail, [{ ...inbox, mayRemoveItems: false }]), null);
  assert.equal(jmap.archiveTarget(mail, [{ ...inbox, archiveDestinationId: undefined }]), null);
  assert.equal(jmap.archiveTarget(mail, [archiveBox({ id: 'inbox', role: 'inbox' })]), null);
  assert.equal(jmap.archiveTarget({ ...mail, id: 'local_archive_saved' }, boxes), null);
  assert.equal(jmap.archiveTarget(mail, [...boxes, archiveBox()]).id, 'archive');
  assert.equal(jmap.archiveTarget(mail, [...boxes, archiveBox(), archiveBox({ id: 'other' })]), null);
});
test('Only a complete safe Inbox hint enables first-use Archive', () => {
  const valid = archiveBox({ id: 'inbox', role: 'inbox', archiveDestinationId: 'prospective', archiveDestinationName: 'Archive' });
  for (const changes of [{ archiveDestinationId: 'inbox' }, { archiveDestinationId: '../archive' },
    { archiveDestinationName: '' }, { archiveDestinationName: 'Archive\nINBOX' }, { archiveDestinationName: 'x'.repeat(1025) },
    { role: 'sent' }, { archiveDestinationName: undefined }]) {
    assert.equal(jmap.validArchiveDestinationHint({ ...valid, ...changes }), false);
  }
  assert.equal(jmap.validArchiveDestinationHint(valid), true);
  assert.equal(jmap.validArchiveDestinationHint(archiveBox()), true);
});
test('Native Archive validates the confirmed folder descriptor before cache publication', async () => {
  const actual = { ...receipt(), archiveMailbox: archiveBox() };
  assert.deepEqual(await imap(async () => ({ archive: actual })).client.archiveEmail('default', 'inbox_uid'), actual);
  for (const box of [null, [], archiveBox({ id: 'wrong' }), archiveBox({ role: 'inbox' }),
    archiveBox({ name: '\n' }), archiveBox({ totalEmails: -1 }), archiveBox({ mayAddItems: 'true' }),
    archiveBox({ archiveDestinationId: 'elsewhere', archiveDestinationName: 'Archive' })]) {
    const f = imap(async () => ({ archive: { ...receipt(), archiveMailbox: box } }));
    await assert.rejects(f.client.archiveEmail('default', 'inbox_uid'), { code: 'changeUnconfirmed' });
    assert.equal(f.calls.length, 1);
  }
});
test('Confirmed actual Archive replaces a stale creation hint and publishes one local folder revision', async () => {
  const actual = archiveBox({ id: 'actual' });
  const f = operations(async () => ({ ...receipt(), archiveId: 'actual', expectedMailboxIds: ['actual'], archiveMailbox: actual }));
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['prospective']);
  assert.equal(f.ops.mailboxRevision('local-account'), 0);
  await f.ops.whenIdle();
  assert.deepEqual(f.records.moved, [['local-account', 'inbox_uid', 'archive_uid', ['actual'], actual]]);
  assert.equal(f.ops.mailboxRevision('local-account'), 1);
  assert.equal(f.ops.mailboxRevision('other-account'), 0);
  assert.equal(f.records.network.length, 1);
});
test('Refused CREATE and failed cache commit never publish a folder revision or Undo', async () => {
  for (const failCache of [false, true]) {
    const f = operations(async () => {
      if (!failCache) throw new jmap.JmapError('forbidden');
      return { ...receipt(), archiveMailbox: archiveBox() };
    });
    if (failCache) f.store.mail.moveEmailIdentity = async () => { throw Error('Synthetic transaction failure'); };
    f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['prospective']);
    await f.ops.whenIdle();
    assert.equal(f.ops.mailboxRevision('local-account'), 0);
    assert.equal(f.ops.undo('local-account'), null);
    assert.equal(f.records.network.length, 1);
    if (!failCache) assert.deepEqual(f.records.membership, [['local-account', 'inbox_uid', ['inbox']]]);
  }
});

test('Delete dispatches its explicit native operation and Undo keeps its action', async () => {
  const deletion = { ...receipt(), action: 'delete', archiveId: 'trash', expectedMailboxIds: ['trash'], movedEmailId: 'trash_uid' };
  const f = imap(request => request.operation === 'undoDelete' ? { state: 'moved', movedEmailId: 'restored_uid' } : { archive: deletion });
  const undo = await f.client.deleteEmail('default', 'inbox_uid');
  assert.equal(f.calls[0].operation, 'deleteEmail'); assert.equal(undo.action, 'delete');
  assert.equal(await f.client.undoArchive({ ...undo, emailId: 'trash_uid' }), 'restored_uid');
  assert.equal(f.calls[1].operation, 'undoDelete');
  await assert.rejects(imap(() => ({ archive: receipt() })).client.deleteEmail('default', 'inbox_uid'), /changeUnconfirmed/);
});

test('Delete preserves confirmed cache identity and offers Undo without invoking Archive', async () => {
  const f = operations(async () => 'restored_uid');
  f.client.deleteEmail = async () => ({ ...receipt(), action: 'delete', archiveId: 'trash', expectedMailboxIds: ['trash'], movedEmailId: 'trash_uid' });
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['trash'], undefined, 'delete');
  await f.ops.whenIdle();
  assert.equal(f.records.network.length, 0);
  assert.deepEqual(f.records.moved[0], ['local-account', 'inbox_uid', 'trash_uid', ['trash']]);
  const undo = f.ops.undo('local-account');
  assert.equal(undo.action, 'delete'); assert.equal(f.ops.notice('local-account'), 'message_deleted');
  f.ops.move(f.store, f.client, 'local-account', 'default', { ...f.mail, id: 'trash_uid' }, ['inbox'], undo);
  await f.ops.whenIdle();
  assert.equal(f.ops.notice('local-account'), 'delete_undone');
  assert.equal(f.ops.currentEmailId('local-account', 'inbox_uid'), 'restored_uid');
});

test('Delete needs an existing unambiguous Trash, independently of Archive creation', () => {
  const inbox = { id: 'inbox', role: 'inbox', mayRemoveItems: true, archiveDestinationId: 'new_archive', archiveDestinationName: 'Archive' };
  const trash = { id: 'trash', role: 'trash', mayAddItems: true };
  const mail = { id: 'server_uid', mailboxIds: ['inbox'] };
  assert.equal(jmap.trashTarget(mail, [inbox]), null);
  assert.equal(jmap.trashTarget(mail, [inbox, trash]), trash);
  assert.equal(jmap.trashTarget(mail, [inbox, trash, { ...trash, id: 'other' }]), null);
  assert.equal(jmap.trashTarget(mail, [inbox, { ...trash, mayAddItems: false }]), null);
  assert.equal(jmap.trashTarget({ ...mail, id: 'local_sent_copy' }, [inbox, trash]), null);
});

test('Delete discovers its destination from the native receipt when no writable Trash was cached', async () => {
  const f = operations(async () => { throw new Error('Archive must not be invoked'); });
  let calls = 0;
  f.client.deleteEmail = async () => { calls++; return { ...receipt(), action: 'delete', archiveId: 'trash',
    expectedMailboxIds: ['trash'], movedEmailId: 'trash_uid', archiveMailbox: archiveBox({ id: 'trash', name: 'Trash', role: 'trash' }) }; };
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['inbox'], undefined, 'delete');
  await f.ops.whenIdle();
  assert.equal(calls, 1);
  assert.deepEqual(f.records.moved[0].slice(0, 4), ['local-account', 'inbox_uid', 'trash_uid', ['trash']]);
  assert.equal(f.records.moved[0][4].role, 'trash');
  assert.equal(f.ops.notice('local-account'), 'message_deleted');
});

test('Unavailable Trash reports a specific failure and retains Inbox membership without retry', async () => {
  const f = operations(async () => { throw new Error('Archive must not be invoked'); });
  let calls = 0;
  f.client.deleteEmail = async () => { calls++; throw new jmap.JmapError('archiveUnavailable'); };
  f.ops.move(f.store, f.client, 'local-account', 'default', f.mail, ['inbox'], undefined, 'delete');
  await f.ops.whenIdle();
  assert.equal(calls, 1); assert.deepEqual(f.records.moved, []);
  assert.deepEqual(f.records.membership, [['local-account', 'inbox_uid', ['inbox']]]);
  assert.equal(f.ops.notice('local-account'), 'trash_unavailable');
  assert.equal(f.ops.pending('local-account', 'inbox_uid'), false);
});
