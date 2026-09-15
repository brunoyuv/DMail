const { test } = require('node:test');
const assert = require('node:assert/strict');
const { automaticMailFixture, flush } = require('./fixtures/automatic-mail-work.cjs');
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

test('Automatic requests are serial and leave at least three nonblocking seconds after completion', async () => {
  const f = automaticMailFixture(), work = f.AutomaticMailWork, first = deferred(), starts = [];
  const a = work.run(async () => { starts.push(f.state.now); await first.promise; return 'a'; });
  const b = work.run(async () => { starts.push(f.state.now); return 'b'; });
  const c = work.run(async () => { starts.push(f.state.now); return 'c'; });
  await f.advance(9000); assert.equal(starts.length, 1, 'long request owns lane without a polling timer');
  assert.equal(f.timers.size, 0);
  first.resolve(); assert.equal(await a, 'a'); await flush();
  await f.advance(2999); assert.equal(starts.length, 1);
  await f.advance(1); assert.equal(await b, 'b'); assert.equal(starts[1] - starts[0], 12000);
  await f.advance(3000); assert.equal(await c, 'c'); assert.equal(starts[2] - starts[1], 3000);
  assert.equal(f.timers.size, 0);
});
test('Failures preserve spacing and do not strand later automatic work', async () => {
  const f = automaticMailFixture(), starts = [];
  await assert.rejects(f.AutomaticMailWork.run(async () => { starts.push(f.state.now); throw new Error('synthetic'); }), /synthetic/);
  const next = f.AutomaticMailWork.run(async () => { starts.push(f.state.now); return 2; });
  await f.advance(2999); assert.equal(starts.length, 1);
  await f.advance(1); assert.equal(await next, 2); assert.equal(starts[1] - starts[0], 3000);
  assert.equal(f.timers.size, 0);
});
test('Cancellation retires queued stale work promptly without starting it or polling an empty lane', async () => {
  const f = automaticMailFixture(), starts = []; let active = true;
  await f.AutomaticMailWork.run(async () => starts.push('first')); await flush();
  const pending = f.AutomaticMailWork.run(async () => starts.push('stale'), () => active);
  const rejected = assert.rejects(pending, f.AutomaticMailWorkCancelled);
  assert.equal(f.timers.size, 1); active = false; f.AutomaticMailWork.cancelInactive(); await rejected;
  assert.equal(f.timers.size, 0); await f.advance(30000); assert.deepEqual(starts, ['first']);
  await f.AutomaticMailWork.run(async () => starts.push('fresh')); assert.deepEqual(starts, ['first', 'fresh']);
});
test('Ownership is checked again after the wait even without an explicit cancellation notification', async () => {
  const f = automaticMailFixture(); let active = true, started = false;
  await f.AutomaticMailWork.run(async () => {});
  const pending = f.AutomaticMailWork.run(async () => { started = true; }, () => active);
  const rejected = assert.rejects(pending, f.AutomaticMailWorkCancelled);
  active = false; await f.advance(3000); await rejected;
  assert.equal(started, false); assert.equal(f.timers.size, 0);
});
test('Canceled jobs behind active work do not consume another interval or affect another owner', async () => {
  const f = automaticMailFixture(), gate = deferred(), order = []; let active = true;
  const first = f.AutomaticMailWork.run(async () => { await gate.promise; order.push('first'); });
  const canceled = f.AutomaticMailWork.run(async () => order.push('stale'), () => active);
  const rejected = assert.rejects(canceled, f.AutomaticMailWorkCancelled);
  const next = f.AutomaticMailWork.run(async () => order.push('next'));
  active = false; f.AutomaticMailWork.cancelInactive(); await rejected; gate.resolve(); await first;
  await f.advance(3000); await next; assert.deepEqual(order, ['first', 'next']);
  assert.equal(f.timers.size, 0);
});
test('Clock rollback creates one bounded rest and inactive predicates cannot strand the lane', async () => {
  const f = automaticMailFixture(); await f.AutomaticMailWork.run(async () => {}); await flush();
  f.state.now -= 3600000;
  const result = f.AutomaticMailWork.run(async () => 'done');
  assert.deepEqual([...f.timers.values()].map(timer => timer.delay), [3000]);
  await f.advance(3000); assert.equal(await result, 'done');
  await assert.rejects(f.AutomaticMailWork.run(async () => assert.fail('must not run'), () => { throw new Error('retired'); }), f.AutomaticMailWorkCancelled);
  assert.equal(f.timers.size, 0);
});
