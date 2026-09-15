// MPL-2.0: https://mozilla.org/MPL/2.0/
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/MailActionSettingsPanel.ets', 'utf8');
const methods = ['load', 'choose'].map(name => source.match(new RegExp(`  private async ${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const code = ts.transpileModule(`class Panel { ${methods} }; return Panel;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const pending = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { resolve, reject, promise }; };
function fixture() {
  const state = { revision: 0, reads: [], writes: [], read: null, save: null };
  const Panel = new Function('AppStorage', code)({ get: () => state.revision, setOrCreate: (_key, value) => { state.revision = value; } });
  const panel = Object.assign(new Panel(), { active: true, accountId: 'a', revision: 0, action: 'archive', ready: false,
    store: { mailAction: async id => { state.reads.push(id); return state.read ? state.read(id) : 'archive'; },
      saveMailAction: async (id, action) => { state.writes.push([id, action]); if (state.save) await state.save(); } }
  });
  return { panel, state };
}
test('Only a persisted choice notifies the inbox while a pending choice stays disabled', async () => {
  const { panel, state } = fixture(), gate = pending(); await panel.load();
  state.save = () => gate.promise;
  const saving = panel.choose('delete'); await panel.choose('delete');
  assert.equal(panel.action, 'delete'); assert.equal(panel.busy, true); assert.equal(state.revision, 0);
  gate.resolve(); await saving;
  assert.deepEqual(state.writes, [['a', 'delete']]);
  assert.equal(panel.action, 'delete'); assert.equal(panel.busy, false); assert.equal(state.revision, 1);
});
test('A failed preference write keeps the previous action and permits a deliberate retry', async () => {
  const { panel, state } = fixture(); await panel.load();
  state.save = async () => { throw Error('Synthetic storage failure'); };
  await panel.choose('delete');
  assert.equal(panel.action, 'archive'); assert.equal(panel.failed, true); assert.equal(state.revision, 0);
  state.save = null; await panel.choose('delete');
  assert.equal(panel.action, 'delete'); assert.equal(panel.failed, false);
});
test('Account switches reject stale loads and keep an in-flight save bound to its original account', async () => {
  const { panel, state } = fixture(), reading = pending(), saving = pending();
  state.read = () => reading.promise; const old = panel.load();
  panel.accountId = 'b'; state.read = async () => 'delete'; await panel.load();
  reading.resolve('archive'); await old; assert.equal(panel.action, 'delete');
  state.save = () => saving.promise; const write = panel.choose('archive');
  panel.accountId = 'a'; state.read = async () => 'delete'; await panel.load();
  saving.resolve(); await write;
  assert.deepEqual(state.writes, [['b', 'archive']]); assert.equal(panel.action, 'delete');
  assert.equal(state.revision, 1);
});
