const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compile = source => ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
} }).outputText;
const microtasks = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
function fixture() {
  const queueModule = { exports: {} }, timers = new Map(); let nextTimer = 0;
  new Function('module', 'exports', 'setTimeout', 'clearTimeout', compile(fs.readFileSync(
    'harmony/entry/src/main/ets/pages/DeferredSave.ts', 'utf8')))(queueModule, queueModule.exports,
    callback => { const id = ++nextTimer; timers.set(id, callback); return id; }, id => timers.delete(id));
  const source = fs.readFileSync('harmony/entry/src/main/ets/pages/Settings.ets', 'utf8');
  const names = ['chooseAccount', 'scheduleComposition', 'saveComposition'];
  const methods = names.map(name => source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n') +
    source.match(/  aboutToDisappear\([\s\S]*?\n  }/)[0];
  const Host = new Function(compile(`class Host { ${methods} }; return Host;`))();
  const state = { failure: false, saveGates: [], reads: [], writes: [] };
  const saved = new Map([['a', { senderName: 'Old Alice', signature: 'Old A' }], ['b', { senderName: 'Bob', signature: 'B' }]]);
  let pending = Promise.resolve();
  const store = {
    saveComposition: (id, settings) => {
      const snapshot = { ...settings };
      const task = pending.catch(() => {}).then(async () => {
        state.writes.push({ id, ...snapshot });
        const gate = state.saveGates.shift(); if (gate) await gate;
        if (state.failure) throw new Error('Synthetic save failure');
        saved.set(id, snapshot);
      });
      pending = task.catch(() => {}); return task;
    },
    composition: async id => { await pending; state.reads.push(id); return { ...saved.get(id) }; }
  };
  const host = Object.assign(new Host(), { active: true, compositionReady: true, compositionFailed: false,
    selectedAccount: 'a', accountGeneration: 1, selectionRevision: 0, saveRevision: 0,
    senderName: 'Alice edited', signature: 'A edited', saves: new queueModule.exports.DeferredSave(), store });
  return { host, state, saved, timers };
}

test('A rejected account-switch save preserves edited settings and retries before a later switch', async () => {
  const f = fixture(); f.state.failure = true; f.host.scheduleComposition();
  await f.host.chooseAccount('b');
  assert.equal(f.host.selectedAccount, 'a'); assert.equal(f.host.senderName, 'Alice edited');
  assert.equal(f.host.signature, 'A edited'); assert.equal(f.host.compositionReady, true);
  assert.equal(f.host.compositionFailed, true); assert.deepEqual(f.state.reads, []);
  f.state.failure = false; await f.host.chooseAccount('b');
  assert.deepEqual(f.saved.get('a'), { senderName: 'Alice edited', signature: 'A edited' });
  assert.equal(f.host.selectedAccount, 'b'); assert.equal(f.host.senderName, 'Bob');
  assert.equal(f.host.compositionFailed, false);
});

test('Rapid A to B to A picker choices apply only the final selection after a slow save', async () => {
  const f = fixture(), gate = deferred(); f.state.saveGates.push(gate.promise); f.host.scheduleComposition();
  const first = f.host.chooseAccount('b'); await microtasks();
  const latest = f.host.chooseAccount('a');
  assert.equal(f.host.selectedAccount, 'a'); assert.equal(f.host.senderName, 'Alice edited');
  gate.resolve(); await Promise.all([first, latest]);
  assert.deepEqual(f.state.reads, ['a']); assert.equal(f.host.selectedAccount, 'a');
  assert.equal(f.host.senderName, 'Alice edited');
});

test('Edits made while a boundary waits must finish saving before the picker replaces them', async () => {
  const f = fixture(), first = deferred(), second = deferred();
  f.state.saveGates.push(first.promise, second.promise); f.host.scheduleComposition();
  const switching = f.host.chooseAccount('b'); await microtasks();
  f.host.senderName = 'Alice newest'; f.host.scheduleComposition();
  first.resolve(); await microtasks();
  assert.equal(f.state.writes.length, 2); assert.equal(f.host.selectedAccount, 'a');
  second.reject(new Error('Synthetic final write rejected')); await switching;
  assert.equal(f.host.selectedAccount, 'a'); assert.equal(f.host.senderName, 'Alice newest');
  assert.equal(f.host.compositionFailed, true); assert.deepEqual(f.state.reads, []);
});

test('A suspended picker choice cannot replace fields when the settings component reappears', async () => {
  const f = fixture(), gate = deferred(); f.state.saveGates.push(gate.promise); f.host.scheduleComposition();
  const switching = f.host.chooseAccount('b'); await microtasks();
  f.host.aboutToDisappear(); f.host.active = true;
  gate.resolve(); await switching;
  assert.equal(f.host.selectedAccount, 'a'); assert.equal(f.host.senderName, 'Alice edited');
  assert.deepEqual(f.state.reads, []);
});
