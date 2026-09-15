const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

const compile = file => ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function fixture(options = {}) {
  const callbacks = [], calls = { register: 0, unregister: 0, get: 0 };
  const thermal = {
    registerThermalLevelCallback(callback) {
      calls.register++; callbacks.push(callback);
      if (options.registrationLevel !== undefined) callback(options.registrationLevel);
      if (options.registerFails) throw new Error('Synthetic unavailable thermal API');
    },
    unregisterThermalLevelCallback() {
      calls.unregister++;
      if (options.unregisterFails) throw new Error('Synthetic teardown error');
    },
    getLevel() {
      calls.get++;
      if (options.getFails) throw new Error('Synthetic initial level unavailable');
      return options.level ?? 0;
    }
  };
  const module = { exports: {} };
  const noTimer = () => { throw new Error('Thermal observation must not poll'); };
  new Function('require', 'module', 'exports', 'setTimeout', 'setInterval',
    compile('harmony/entry/src/main/ets/mail/MailSyncPower.ets'))(name => {
      assert.equal(name, '@kit.BasicServicesKit'); return { thermal };
    }, module, module.exports, noTimer, noTimer);
  return { Power: module.exports.MailSyncPower, callbacks, calls, options,
    emit: level => callbacks.at(-1)(level) };
}

const pacingModule = { exports: {} };
new Function('module', 'exports', compile('harmony/entry/src/main/ets/mail/MailSyncPacing.ts'))(pacingModule, pacingModule.exports);
const { mailSyncRestMs: rest, mailSyncThermallyAllowed: allowed } = pacingModule.exports;

test('Workers share one thermal subscription and duplicate callback subscriptions have independent lifetimes', () => {
  const f = fixture({ level: 2 }); let events = 0;
  const listener = () => events++;
  const stopOne = f.Power.subscribe(listener), stopTwo = f.Power.subscribe(listener);
  assert.deepEqual(f.calls, { register: 1, unregister: 0, get: 1 });
  assert.equal(f.Power.level(), 2); assert.equal(allowed(f.Power.level()), false);
  f.emit(1); assert.equal(events, 2);
  stopOne(); stopOne(); assert.equal(f.calls.unregister, 0);
  f.emit(0); assert.equal(events, 3);
  stopTwo(); stopTwo(); assert.equal(f.calls.unregister, 1); assert.equal(f.Power.level(), 0);
});

test('Invalid and unchanged readings are ignored, while stale callbacks cannot affect a replacement worker', () => {
  const f = fixture({ level: 1 }); let events = 0;
  const stop = f.Power.subscribe(() => events++);
  for (const level of [1, -1, 8, 1.5, NaN, Infinity]) f.emit(level);
  assert.equal(events, 0); assert.equal(f.Power.level(), 1);
  f.emit(2); f.emit(2); assert.equal(events, 1);
  const stale = f.callbacks[0]; stop(); stale(7); assert.equal(f.Power.level(), 0);
  f.options.level = 0;
  const stopNext = f.Power.subscribe(() => events++);
  stale(7); assert.equal(events, 1); assert.equal(f.Power.level(), 0);
  f.emit(1); assert.equal(events, 2); stopNext();
  assert.equal(f.calls.register, 2); assert.equal(f.calls.unregister, 2);
});

test('A listener removed during dispatch is not invoked, and a failing listener cannot strand other workers', () => {
  const f = fixture(); let remaining = 0, removed = 0, stopRemoved;
  const stopFirst = f.Power.subscribe(() => { stopRemoved(); throw new Error('Synthetic worker failure'); });
  stopRemoved = f.Power.subscribe(() => removed++);
  const stopLast = f.Power.subscribe(() => remaining++);
  assert.doesNotThrow(() => f.emit(2));
  assert.equal(removed, 0); assert.equal(remaining, 1); assert.equal(f.Power.level(), 2);
  stopFirst(); stopLast(); assert.equal(f.calls.unregister, 1);
});

test('An observed registration event outranks a stale initial read and survives an initial read failure', () => {
  for (const getFails of [false, true]) {
    const f = fixture({ registrationLevel: 2, level: 0, getFails });
    const stop = f.Power.subscribe(() => {});
    assert.equal(f.Power.level(), 2); assert.equal(allowed(f.Power.level()), false);
    f.emit(0); assert.equal(f.Power.level(), 0); stop();
  }
});

test('Unavailable initial readings retain ordinary pacing and later valid events recover without polling', () => {
  for (const options of [{ getFails: true }, { level: NaN }, { level: 10 }]) {
    const f = fixture(options); let events = 0;
    const stop = f.Power.subscribe(() => events++);
    assert.equal(f.Power.level(), 0); assert.equal(allowed(f.Power.level()), true);
    assert.equal(rest(0, f.Power.level()), 250);
    f.emit(2); assert.equal(events, 1); assert.equal(allowed(f.Power.level()), false);
    stop(); assert.equal(f.calls.get, 1); assert.equal(f.calls.register, 1);
  }
});

test('Registration or unregister failures cannot leave stale callbacks controlling a new lifetime', () => {
  const f = fixture({ registerFails: true, registrationLevel: 2, unregisterFails: true });
  const stop = f.Power.subscribe(() => { throw new Error('Failed subscription must never emit'); });
  assert.equal(f.Power.level(), 0); assert.equal(f.calls.get, 0);
  f.emit(7); assert.equal(f.Power.level(), 0); stop();
  const stale = f.callbacks[0];
  f.options.registerFails = false; f.options.registrationLevel = undefined; f.options.level = 1;
  const stopNext = f.Power.subscribe(() => {});
  stale(7); assert.equal(f.Power.level(), 1);
  assert.doesNotThrow(stopNext); f.emit(7); assert.equal(f.Power.level(), 0);
});

test('Pacing bounds ordinary and warming work, and all warm-or-hotter platform levels stop bulk sync', () => {
  assert.equal(rest(0, 0), 250); assert.equal(rest(1000, 0), 1000); assert.equal(rest(20000, 0), 5000);
  assert.equal(rest(0, 1), 1000); assert.equal(rest(1000, 1), 2000); assert.equal(rest(20000, 1), 10000);
  for (const invalid of [-1, NaN, Infinity, -Infinity]) {
    assert.equal(rest(invalid, 0), 250); assert.equal(rest(invalid, 1), 1000);
  }
  let previousCool = 0, previousNormal = 0;
  for (let work = 0; work <= 20000; work += 137) {
    const cool = rest(work, 0), normal = rest(work, 1);
    assert.ok(cool >= 250 && cool <= 5000 && cool >= previousCool);
    assert.ok(normal >= 1000 && normal <= 10000 && normal >= previousNormal && normal >= cool);
    previousCool = cool; previousNormal = normal;
  }
  for (let level = 0; level <= 7; level++) assert.equal(allowed(level), level < 2);
});
