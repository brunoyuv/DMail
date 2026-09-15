const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
class BrowserOAuthError extends Error { constructor(code) { super(code); this.code = code; } }
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
function fixture(open = async () => 'http://127.0.0.1:49152/oauth2redirect') {
  const state = { closed: 0, cancelled: 0, completed: 0, launched: 0, listener: null };
  class Listener {
    constructor(handle, failed, completed) { this.handle = handle; this.completed = completed; state.listener = this; }
    open() { return open(); }
    async close() { state.closed++; throw new Error('Synthetic socket cleanup failed'); }
  }
  const oauth = {
    async begin() { return { id: 'synthetic-session', url: 'https://login.example.test/synthetic' }; },
    async complete() { state.completed++; return { accessToken: 'synthetic-token', refreshToken: 'synthetic-refresh' }; },
    async cancel() { state.cancelled++; throw new Error('Synthetic native cleanup failed'); }
  };
  const imports = { './NativeBrowserOAuth': { BrowserOAuthError }, './LoopbackOAuthListener': { LoopbackOAuthListener: Listener } };
  const source = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/oauth/LoopbackBrowserSignIn.ets', 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('require', 'exports', 'module', source)(name => { assert.ok(name in imports, name); return imports[name]; }, module.exports, module);
  return { state, oauth, SignIn: module.exports.LoopbackBrowserSignIn };
}

test('Completed sign-in tokens survive listener/native cleanup failures without repeating authentication', async () => {
  const f = fixture(); const signIn = new f.SignIn(async () => {
    f.state.launched++; assert.equal(await f.state.listener.handle('synthetic-callback'), true); f.state.listener.completed();
  }, f.oauth);
  const tokens = await signIn.signIn('microsoft', 'synthetic-client', 'sender@example.test');
  assert.equal(tokens.accessToken, 'synthetic-token'); assert.equal(f.state.completed, 1); assert.equal(f.state.launched, 1);
  assert.equal(f.state.closed, 1); assert.equal(f.state.cancelled, 1);
  assert.equal(await f.state.listener.handle('late-synthetic-callback'), false);
  await assert.rejects(signIn.signIn('microsoft', 'synthetic-client', 'sender@example.test'), error => error.code === 'alreadyStarted');
});

test('A primary browser failure is preserved while both cleanup operations are attempted', async () => {
  const f = fixture(); const signIn = new f.SignIn(async () => { throw new BrowserOAuthError('network'); }, f.oauth);
  await assert.rejects(signIn.signIn('microsoft', 'synthetic-client', 'sender@example.test'), error => error.code === 'network');
  assert.equal(f.state.closed, 1); assert.equal(f.state.cancelled, 1); assert.equal(f.state.completed, 0);
});

test('Cancellation while opening the listener stays cancellation even if later socket cleanup fails', async () => {
  const gate = deferred(), started = deferred(); const f = fixture(async () => { started.resolve(); return gate.promise; });
  const signIn = new f.SignIn(async () => { f.state.launched++; }, f.oauth);
  const outcome = signIn.signIn('microsoft', 'synthetic-client', 'sender@example.test');
  await started.promise; signIn.cancel(); gate.resolve('http://127.0.0.1:49152/oauth2redirect');
  await assert.rejects(outcome, error => error.code === 'cancelled');
  assert.equal(f.state.launched, 0); assert.equal(f.state.closed, 1); assert.equal(f.state.cancelled, 0);
});
