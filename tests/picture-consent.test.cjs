// Exercise the production renderer's async identity guards without real mail or ArkWeb.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const root = path.resolve(__dirname, '..');
const ts = require(path.join(root, '.tools/test/node_modules/typescript'));
const source = fs.readFileSync(path.join(root, 'harmony/entry/src/main/ets/pages/HtmlMail.ets'), 'utf8');
function method(name) {
  let start = source.indexOf(`  private async ${name}(`);
  if (start < 0) start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }\n', start) + 5).replace('private ', '');
}
const compiled = ts.transpileModule(`class Harness { ${['reload', 'loadPictures', 'refreshPictures', 'cachedPicture'].map(method).join('\n')} }\nHarness;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
const Harness = vm.runInNewContext(compiled);
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture() {
  const choices = new Set(), saved = [];
  const cache = {
    allowed: async (account, message) => choices.has(`${account}:${message}`),
    allow: async (account, message) => { choices.add(`${account}:${message}`); saved.push([account, message]); }
  };
  const make = (account = 'account-a', message = 'message-a') => Object.assign(new Harness(), {
    active: true, identityRevision: 0, pictureCache: cache, accountId: account,
    messageKey: message, remoteImages: false, savingPictures: false,
    checkingPictures: true, pictureSaveFailed: false, pictureRequests: 0, pictureLoadRevision: 0,
    forcePictureRefresh: false, refreshedPictureUrls: new Set(), refreshDocument() {}
  });
  return { choices, saved, cache, make };
}
function response() {
  return {
    ready: false,
    setResponseData(value) { this.data = value; },
    setResponseMimeType(value) { this.mimeType = value; },
    setResponseCode(value) { this.code = value; },
    setReasonMessage(value) { this.reason = value; },
    setResponseIsReady(value) { this.ready = value; }
  };
}
test('Load pictures is remembered across renderer recreation and message switches', async () => {
  const { make, saved } = fixture(); const reader = make();
  await reader.reload(); assert.equal(reader.remoteImages, false);
  await reader.loadPictures(); assert.equal(reader.remoteImages, true);
  const reopened = make(); await reopened.reload(); assert.equal(reopened.remoteImages, true);
  reopened.messageKey = 'message-b'; await reopened.reload(); assert.equal(reopened.remoteImages, false);
  reopened.messageKey = 'message-a'; await reopened.reload(); assert.equal(reopened.remoteImages, true);
  assert.deepEqual(saved, [['account-a', 'message-a']]);
});
test('The same message identity in another account has independent consent', async () => {
  const { make } = fixture(); const reader = make(); await reader.loadPictures();
  const other = make('account-b'); await other.reload(); assert.equal(other.remoteImages, false);
});
test('A delayed saved-choice read cannot grant permission to a later message', async () => {
  const { make, cache } = fixture(); const wait = deferred();
  cache.allowed = (_account, message) => message === 'message-a' ? wait.promise : Promise.resolve(false);
  const reader = make(); const oldRead = reader.reload();
  reader.messageKey = 'message-b'; await reader.reload(); wait.resolve(true); await oldRead;
  assert.equal(reader.remoteImages, false); assert.equal(reader.checkingPictures, false);
});
test('A click persists its original message without enabling the newly selected one', async () => {
  const { make, cache, choices } = fixture(); const wait = deferred();
  cache.allow = async (account, message) => { await wait.promise; choices.add(`${account}:${message}`); };
  const reader = make(); const click = reader.loadPictures();
  reader.messageKey = 'message-b'; await reader.reload(); wait.resolve(); await click;
  assert.equal(reader.remoteImages, false); assert.equal(choices.has('account-a:message-a'), true);
  reader.messageKey = 'message-a'; await reader.reload(); assert.equal(reader.remoteImages, true);
});
test('A stored-choice write failure keeps network pictures blocked', async () => {
  const { make, cache } = fixture(); cache.allow = async () => { throw new Error('synthetic storage failure'); };
  const reader = make(); await reader.loadPictures();
  assert.equal(reader.remoteImages, false); assert.equal(reader.pictureSaveFailed, true); assert.equal(reader.savingPictures, false);
});
test('An in-flight picture response uses the captured account and completes after navigation', async () => {
  const { make } = fixture(); const reader = make(), wait = deferred(), calls = [];
  const cache = { load: (...args) => { calls.push(args); return wait.promise; } };
  const out = response(), bytes = new Uint8Array([137, 80, 78, 71]).buffer;
  const task = reader.cachedPicture(out, cache, 'account-a', 'message-a', 'https://images.example.test/a.png');
  reader.accountId = 'account-b'; reader.messageKey = 'message-b';
  wait.resolve({ data: bytes, mimeType: 'image/png' }); await task;
  assert.deepEqual(calls, [['account-a', 'message-a', 'https://images.example.test/a.png', false]]);
  assert.equal(out.data, bytes); assert.equal(out.mimeType, 'image/png'); assert.equal(out.code, 200); assert.equal(out.ready, true);
});
test('Failed image loads complete the intercepted response without opening browser networking', async () => {
  const { make } = fixture(); const reader = make(), out = response();
  await reader.cachedPicture(out, { load: async () => { throw new Error('offline'); } }, 'account-a', 'message-a', 'https://images.example.test/a.png');
  assert.equal(out.code, 403); assert.equal(out.ready, true); assert.equal(out.data, '');
  assert.equal(reader.pictureRequests, 0);
});
test('Explicit refresh is available only after consent and replaces each URL once per click', async () => {
  const { make, saved } = fixture(); const reader = make(); const refreshes = [];
  const cache = { load: async (_a, _m, _u, refresh) => { refreshes.push(refresh); return null; } };
  const load = url => reader.cachedPicture(response(), cache, reader.accountId, reader.messageKey, url);
  reader.refreshPictures(); assert.equal(reader.forcePictureRefresh, false);
  await reader.reload(); await reader.loadPictures();
  await load('https://images.example.test/a.png');
  reader.refreshPictures();
  await load('https://images.example.test/a.png');
  await load('https://images.example.test/a.png');
  await load('https://images.example.test/b.png');
  reader.refreshPictures(); await load('https://images.example.test/a.png');
  await reader.reload(); await load('https://images.example.test/a.png');
  assert.deepEqual(refreshes, [false, true, false, true, true, false]);
  assert.deepEqual(saved, [['account-a', 'message-a']]);
});
test('A late picture request cannot clear the new message loading state', async () => {
  const { make } = fixture(); const reader = make(), wait = deferred();
  const task = reader.cachedPicture(response(), { load: () => wait.promise }, 'account-a', 'message-a', 'https://images.example.test/a.png');
  assert.equal(reader.pictureRequests, 1);
  reader.messageKey = 'message-b'; await reader.reload();
  reader.pictureRequests = 2;
  wait.resolve(null); await task;
  assert.equal(reader.pictureRequests, 2);
});
