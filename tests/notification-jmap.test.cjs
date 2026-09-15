const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const compiled = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/notifications/NotificationModel.ts', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const model = { exports: {} };
new Function('module', 'exports', compiled)(model, model.exports);
const { compareJmapInbox } = model.exports;
const mail = (id, receivedAt, unread = true) => ({ id, receivedAt, unread });
const page = (cursor, messages, next = null, missing = []) => compareJmapInbox(cursor, 'inbox', messages, next, missing);
const checkpoint = result => JSON.parse(result.state);

test('A complete timestamp group detects distinct equal-time arrivals once, including second-precision servers', () => {
  const first = page('', [mail('first', 1000), mail('older', 900)], 50);
  assert.equal(first.newMessages, 0); assert.equal(checkpoint(first).latestComplete, true);
  const next = page(first.state, [mail('same-second', 1000), mail('first', 1000)], 50);
  assert.equal(next.newMessages, 1);
  const repeat = page(next.state, [mail('same-second', 1000, false), mail('first', 1000)], 50);
  assert.equal(repeat.newMessages, 0);
  assert.equal(page(repeat.state, [mail('same-second', 1000), mail('first', 1000)], 50).newMessages, 0);
  const finalPage = page('', [mail('only', 1000)]);
  assert.equal(page(finalPage.state, [mail('new', 1000), mail('only', 1000)]).newMessages, 1);
});

test('A truncated all-equal page never mistakes an older unseen timestamp peer for a new arrival', () => {
  const initial = Array.from({ length: 50 }, (_, index) => mail(`old-${index}`, 1000));
  const first = page('', initial, 50);
  assert.equal(checkpoint(first).latestComplete, false);
  const exposed = page(first.state, initial.slice(1).concat(mail('old-beyond-first-page', 1000)), 50);
  assert.equal(exposed.newMessages, 0); assert.equal(checkpoint(exposed).latestComplete, false);
  const complete = page(exposed.state, [mail('old-beyond-first-page', 1000), mail('older', 900)], 50);
  assert.equal(complete.newMessages, 0); assert.equal(checkpoint(complete).latestComplete, true);
  assert.equal(page(complete.state, [mail('actual-arrival', 1000), mail('old-beyond-first-page', 1000)]).newMessages, 1);
});

test('Missing query rows or absent page metadata cannot claim a timestamp group is complete', () => {
  const first = page('', [mail('first', 1000), mail('older', 900)], null, ['missing-message']);
  assert.equal(checkpoint(first).latestComplete, false);
  assert.equal(page(first.state, [mail('missing-message', 1000), mail('first', 1000)]).newMessages, 0);
  const noMetadata = compareJmapInbox('', 'inbox', [mail('first', 1000), mail('older', 900)]);
  assert.equal(checkpoint(noMetadata).latestComplete, false);
});

test('Version-2 cursor upgrade keeps ties conservative and pins the old known IDs', () => {
  const old = JSON.stringify({ version: 2, mailboxId: 'inbox', ids: ['previous-known'], latest: 1000 });
  const upgraded = page(old, [mail('previously-unknown-peer', 1000), mail('older', 900)]);
  assert.equal(upgraded.newMessages, 0); assert.equal(checkpoint(upgraded).latestComplete, true);
  assert.ok(checkpoint(upgraded).latestIds.includes('previous-known'));
  assert.equal(page(upgraded.state, [mail('previous-known', 1000)]).newMessages, 0);
  assert.equal(page(upgraded.state, [mail('new-peer', 1000)]).newMessages, 1);
});

test('Timestamp peer IDs survive more than 500 older page entries without reappearance alerts', () => {
  let result = page('', [mail('original-peer', 1000), mail('older', 900)]);
  for (let batch = 0; batch < 12; batch++) {
    result = page(result.state, Array.from({ length: 50 }, (_, index) => mail(`older-${batch}-${index}`, 900 - batch)), 50);
    assert.equal(result.newMessages, 0);
    const saved = checkpoint(result);
    assert.ok(saved.ids.length + saved.latestIds.length <= 500);
    assert.ok(saved.latestIds.includes('original-peer'));
  }
  assert.equal(page(result.state, [mail('original-peer', 1000)]).newMessages, 0);
  assert.equal(page(result.state, [mail('new-peer', 1000), mail('original-peer', 1000)]).newMessages, 1);
});

test('An overflowing timestamp group remains conservative until a newer group resets its bounded history', () => {
  let result = page('', Array.from({ length: 50 }, (_, index) => mail(`peer-0-${index}`, 1000)));
  for (let batch = 1; batch < 10; batch++) {
    result = page(result.state, Array.from({ length: 50 }, (_, index) => mail(`peer-${batch}-${index}`, 1000)));
    assert.equal(result.newMessages, 50);
  }
  result = page(result.state, [mail('overflow-peer', 1000)]);
  assert.equal(result.newMessages, 1); assert.equal(checkpoint(result).latestOverflow, true);
  assert.equal(checkpoint(result).latestComplete, false);
  assert.equal(checkpoint(result).latestIds.length + checkpoint(result).ids.length, 500);
  const absent = page(result.state, [mail('older-page', 900)]);
  assert.equal(checkpoint(absent).latestComplete, false);
  assert.equal(page(absent.state, [mail('overflow-peer', 1000)]).newMessages, 0);
  const newer = page(absent.state, [mail('newer', 2000), mail('overflow-peer', 1000)]);
  assert.equal(newer.newMessages, 1); assert.equal(checkpoint(newer).latestOverflow, false);
  assert.equal(checkpoint(newer).latestComplete, true);
  assert.equal(page(newer.state, [mail('newer-peer', 2000)]).newMessages, 1);
});
