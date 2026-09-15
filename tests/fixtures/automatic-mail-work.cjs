const fs = require('node:fs');
const ts = require('../../.tools/test/node_modules/typescript');
const flush = async () => { for (let i = 0; i < 80; i++) await Promise.resolve(); };
function automaticMailFixture(state = { now: 1800000000000 }) {
  const timers = new Map(); let nextId = 1;
  class Clock extends Date { static now() { return state.now; } }
  const module = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/AutomaticMailWork.ts', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  new Function('module', 'exports', 'Date', 'setTimeout', 'clearTimeout', code)(module, module.exports, Clock,
    (callback, delay) => { const id = nextId++; timers.set(id, { callback, due: state.now + delay, delay }); return id; },
    id => timers.delete(id));
  const advance = async milliseconds => {
    await flush(); const target = state.now + milliseconds;
    for (;;) {
      const next = [...timers].sort((a, b) => a[1].due - b[1].due)[0];
      if (!next || next[1].due > target) break;
      state.now = next[1].due; timers.delete(next[0]); next[1].callback(); await flush();
    }
    state.now = target; await flush();
  };
  const settle = async promise => {
    let done = false, result, failure;
    promise.then(value => { done = true; result = value; }, error => { done = true; failure = error; });
    for (let i = 0; i < 100; i++) {
      await flush(); if (done) { if (failure) throw failure; return result; }
      const timer = [...timers.values()].sort((a, b) => a.due - b.due)[0];
      if (!timer) throw new Error('Synthetic operation stalled without a timer');
      await advance(Math.max(0, timer.due - state.now));
    }
    throw new Error('Synthetic automatic work did not settle');
  };
  return { ...module.exports, state, timers, Clock, advance, settle, flush };
}
module.exports = { automaticMailFixture, flush };
