const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const clone = value => JSON.parse(JSON.stringify(value));
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
async function microtasks() { for (let index = 0; index < 20; index++) { await Promise.resolve(); } }
function method(name) {
  const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ComposeMail.ets', 'utf8');
  const start = source.match(new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm'));
  assert.ok(start, `Actual ComposeMail.${name} method must exist`);
  const lineEnd = source.indexOf('\n', start.index);
  if (source.slice(start.index, lineEnd).trimEnd().endsWith('}')) { return source.slice(start.index, lineEnd); }
  const end = source.indexOf('\n  }', start.index);
  assert.ok(end > start.index, `Actual ComposeMail.${name} body must close`);
  return source.slice(start.index, end + 4);
}
function draft(id = '10000000-0000-0000-0000-000000000001') {
  return { id, date: 123, state: 'draft', to: '', cc: '', bcc: '', text: '', subject: '', forwardHtml: '', attachments: [] };
}
function attachment(number = 1, size = 7) {
  return { id: `20000000-0000-0000-0000-${String(number).padStart(12, '0')}`, name: `附件 ${number}.pdf`,
    contentType: 'application/pdf', size, file: `opaque-private-${number}.bin` };
}
function fixture() {
  const state = { selections: [], imports: [], removals: [], writes: [], events: [], sends: 0, sending: false,
    pick: async () => [], import: async (_account, _draft, _uri, _remaining, active) => {
      assert.equal(active(), true); return attachment(state.imports.length);
    }, remove: async () => {}, save: async () => {}, outgoing: new Map(), timers: new Map() };
  let timerId = 0;
  const queueModule = { exports: {} };
  new Function('module', 'exports', 'setTimeout', 'clearTimeout', compile(fs.readFileSync('harmony/entry/src/main/ets/pages/DeferredSave.ts', 'utf8')))(
    queueModule, queueModule.exports, callback => { state.timers.set(++timerId, callback); return timerId; }, id => state.timers.delete(id));
  const background = { isSending: () => state.sending, wasAccepted: () => false,
    queue: async () => { state.sends++; }, publish() {} };
  const picker = { DocumentViewPicker: class {
    constructor(context) { assert.equal(context.filesDir, '/synthetic/private'); }
    select(options) { state.selections.push(clone(options)); return state.pick(options); }
  } };
  class Files {
    constructor(path) { assert.equal(path, '/synthetic/private'); }
    async importURI(account, id, uri, remaining, active) {
      state.imports.push({ account, id, uri, remaining, active });
      return state.import(account, id, uri, remaining, active);
    }
    async remove(account, id, value) {
      state.events.push('remove'); state.removals.push({ account, id, value: clone(value) });
      return state.remove(account, id, value);
    }
  }
  const names = ['editable', 'attachFiles', 'removeAttachment', 'scheduleSave', 'save', 'initialize', 'send', 'aboutToDisappear'];
  const Host = new Function('BackgroundSend', 'picker', 'OutgoingAttachmentFiles', 'OUTGOING_ATTACHMENT_COUNT',
    'OUTGOING_ATTACHMENT_BYTES', 'setSendFailure', 'sendFailureLabel', 'sendFailureDiagnostic',
    compile(`class Host { ${names.map(method).join('\n')} }; return Host;`))(
    background, picker, Files, 10, 10 * 1024 * 1024, () => {}, value => value, () => '');
  const host = new Host();
  Object.assign(host, { account: { id: 'account-a' }, draft: draft(), active: true, ready: true, busy: false,
    attachmentPicking: false, attachmentNotice: '', attachmentRevision: 0,
    notice: '', saveRevision: 0, initializeRevision: 0, saveFailed: false, recipientField: 'to', password: 'synthetic',
    host: 'example.invalid', username: 'synthetic', onQueued() {}, label: name => name,
    getUIContext: () => ({ getHostContext: () => ({ filesDir: '/synthetic/private' }) }),
    loadRecipients() {}, savedFailureNotice: () => '', settings: () => ({}),
    saves: new queueModule.exports.DeferredSave(),
    store: { saveOutgoing: async (account, value) => {
      const snapshot = clone(value); state.events.push('save-start');
      await state.save(account, snapshot);
      state.writes.push({ account, draft: snapshot }); state.events.push('save-end');
    }, outgoing: async account => state.outgoing.get(account) ?? host.draft,
    smtp: async () => ({ endpoint: 'smtp://example.invalid:587', username: 'synthetic', password: 'synthetic' }) }
  });
  return { host, state, async change(account = 'account-b') {
    const next = draft('10000000-0000-0000-0000-000000000002'); state.outgoing.set(account, next);
    host.account = { id: account }; await host.initialize(); return next;
  } };
}

test('Actual composer imports selected files with remaining budgets and saves only small metadata', async () => {
  const f = fixture(); f.host.draft.attachments = [attachment(8, 1024)];
  f.state.pick = async () => ['file://synthetic/one', 'file://synthetic/two'];
  await f.host.attachFiles();
  assert.deepEqual(f.state.selections, [{ maxSelectNumber: 9 }]);
  assert.deepEqual(f.state.imports.map(value => value.remaining), [10 * 1024 * 1024 - 1024, 10 * 1024 * 1024 - 1031]);
  assert.equal(f.state.writes.at(-1).account, 'account-a');
  assert.equal(f.state.writes.at(-1).draft.attachments.length, 3);
  assert.ok(f.state.writes.every(value => JSON.stringify(value).length < 2048));
  assert.ok(!JSON.stringify(f.state.writes).includes('base64'));
  assert.equal(f.host.attachmentPicking, false); assert.equal(f.host.editable(), true);
  assert.equal(f.state.timers.size, 0);
});

test('An old picker result cannot import into a replacement account/draft or leave it locked', async () => {
  const f = fixture(), oldPicker = deferred(); f.state.pick = () => oldPicker.promise;
  const first = f.host.attachFiles(); assert.equal(f.host.editable(), false);
  const replacement = await f.change();
  oldPicker.resolve(['file://synthetic/stale']); await first;
  assert.equal(f.host.draft, replacement); assert.equal(f.state.imports.length, 0); assert.equal(f.state.writes.length, 0);
  assert.deepEqual(replacement.attachments, []); assert.equal(f.host.editable(), true);
});

test('A retired import sees an inactive ownership callback and never writes into the next draft', async () => {
  const f = fixture(), importGate = deferred(); f.state.pick = async () => ['file://synthetic/one'];
  f.state.import = () => importGate.promise;
  const first = f.host.attachFiles(); await microtasks(); assert.equal(f.state.imports.length, 1);
  const ownership = f.state.imports[0].active, replacement = await f.change('account-a');
  assert.equal(ownership(), false); importGate.resolve(attachment()); await first;
  assert.deepEqual(replacement.attachments, []); assert.equal(f.state.writes.length, 0);
  assert.equal(f.host.editable(), true);
});

test('An older picker finishing cannot unlock a new picker for a replacement draft', async () => {
  const f = fixture(), oldPicker = deferred(), newPicker = deferred(); let calls = 0;
  f.state.pick = () => ++calls === 1 ? oldPicker.promise : newPicker.promise;
  const old = f.host.attachFiles(); await f.change();
  const next = f.host.attachFiles(); assert.equal(f.state.selections.length, 2);
  oldPicker.resolve(['file://synthetic/stale']); await old;
  assert.equal(f.host.attachmentPicking, true); assert.equal(f.host.editable(), false);
  newPicker.resolve([]); await next;
  assert.equal(f.host.editable(), true); assert.equal(f.state.imports.length, 0);
});

test('Composer removal persists the detached metadata before deleting the owned file', async () => {
  const f = fixture(), saveGate = deferred(), value = attachment(); f.host.draft.attachments = [value];
  f.state.save = () => saveGate.promise;
  const removing = f.host.removeAttachment(value.id); await microtasks();
  assert.deepEqual(f.state.removals, []); assert.equal(f.state.events[0], 'save-start');
  saveGate.resolve(); await removing;
  assert.deepEqual(f.state.writes.at(-1).draft.attachments, []);
  assert.deepEqual(f.state.events, ['save-start', 'save-end', 'remove']);
  assert.equal(f.state.removals[0].account, 'account-a'); assert.equal(f.state.removals[0].id, f.host.draft.id);
  assert.equal(f.state.removals[0].value.id, value.id); assert.equal(f.host.editable(), true);
});

test('A failed removal save retains the file and shows a local save error without automatic deletion', async () => {
  const f = fixture(), value = attachment(); f.host.draft.attachments = [value];
  f.state.save = async () => { throw new Error('Synthetic local write failure'); };
  await f.host.removeAttachment(value.id); await f.host.saves.flush().catch(() => {});
  assert.equal(f.state.removals.length, 0); assert.equal(f.state.writes.length, 0);
  assert.equal(f.host.saveFailed, true);
  assert.equal(f.host.editable(), true);
});

test('A removal completing after account replacement deletes only the original draft file', async () => {
  const f = fixture(), saveGate = deferred(), value = attachment(); f.host.draft.attachments = [value];
  const oldDraftId = f.host.draft.id;
  f.state.save = () => saveGate.promise;
  const removing = f.host.removeAttachment(value.id); await microtasks();
  const replacement = await f.change();
  saveGate.resolve(); await removing;
  assert.deepEqual(replacement.attachments, []);
  assert.deepEqual(f.state.writes.map(write => write.account), ['account-a']);
  assert.deepEqual(f.state.removals, [{ account: 'account-a', id: oldDraftId, value }]);
});

test('Sending, sent, uncertain and otherwise locked composers cannot pick, remove or send attachments', async () => {
  for (const state of ['sending', 'sent', 'unconfirmed', 'busy', 'picking', 'not-ready', 'job-active']) {
    const f = fixture(), value = attachment(); f.host.draft.attachments = [value];
    if (['sending', 'sent', 'unconfirmed'].includes(state)) { f.host.draft.state = state; }
    if (state === 'busy') { f.host.busy = true; }
    if (state === 'picking') { f.host.attachmentPicking = true; }
    if (state === 'not-ready') { f.host.ready = false; }
    if (state === 'job-active') { f.state.sending = true; }
    await f.host.attachFiles(); await f.host.removeAttachment(value.id); await f.host.send();
    assert.deepEqual(f.host.draft.attachments, [value], state);
    assert.equal(f.state.selections.length, 0, state); assert.equal(f.state.writes.length, 0, state);
    assert.equal(f.state.removals.length, 0, state); assert.equal(f.state.sends, 0, state);
  }
});

test('Leaving the composer during picker selection suppresses late imports and errors', async () => {
  const f = fixture(), picked = deferred(); f.state.pick = () => picked.promise;
  const operation = f.host.attachFiles(); f.host.aboutToDisappear();
  picked.reject(new Error('Synthetic picker cancellation')); await operation;
  assert.equal(f.state.imports.length, 0); assert.equal(f.state.writes.length, 0);
  assert.equal(f.host.attachmentNotice, ''); assert.equal(f.host.password, '');
});
