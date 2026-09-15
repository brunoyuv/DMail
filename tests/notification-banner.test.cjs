const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
function fixture() {
  const values = new Map(); let foreground = true;
  const source = fs.readFileSync('harmony/entry/src/main/ets/mail/notifications/MailBannerNotice.ets', 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', 'AppStorage', code)(() => ({ MailInboxUpdates: { isForeground: () => foreground } }), module, module.exports,
    { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) });
  return { banner: module.exports.MailBannerNotice, values, setForeground(value) { foreground = value; } };
}
test('Foreground banner coalesces duplicate delivery and routes only after an explicit tap', () => {
  const f = fixture(); f.banner.show('account-a', 1); f.banner.show('account-a', 1);
  assert.equal(f.values.get('mailBannerRevision'), 1);
  assert.equal(f.values.has('mailNotificationAccountId'), false);
  f.banner.dismiss(); assert.equal(f.values.get('mailBannerAccountId'), '');
  assert.equal(f.values.has('mailNotificationAccountId'), false);
  f.banner.show('account-b', 1); f.banner.open();
  assert.equal(f.values.get('mailBannerAccountId'), '');
  assert.equal(f.values.get('mailNotificationAccountId'), 'account-b');
  assert.equal(f.values.get('mailNotificationOpenRevision'), 1);
});
test('Background delivery does not leave a stale foreground banner to replay on resume', () => {
  const f = fixture(); f.setForeground(false); f.banner.show('account-a', 1);
  assert.equal(f.values.size, 0);
  f.setForeground(true); f.banner.show('account-a', 1); assert.equal(f.values.size, 0);
  f.banner.show('account-a', 2); assert.equal(f.values.get('mailBannerAccountId'), 'account-a');
});

test('Cache arrivals work independently of OS delivery and group with a matching foreground notice', () => {
  const f = fixture(); f.banner.showInboxArrival('account-a', 20);
  assert.equal(f.values.get('mailBannerRevision'), 1);
  f.banner.show('account-a', 1); assert.equal(f.values.get('mailBannerRevision'), 1);
  f.banner.dismiss(); f.banner.showInboxArrival('account-a', 21);
  assert.equal(f.values.get('mailBannerAccountId'), 'account-a');
});

test('Disabling or removing the account dismisses its visible banner without navigating or affecting another enabled account', () => {
  const f = fixture(); f.banner.showInboxArrival('account-a', 1);
  f.banner.reconcile([{ accountId: 'account-a', enabled: true }, { accountId: 'account-b', enabled: false }]);
  assert.equal(f.values.get('mailBannerAccountId'), 'account-a');
  f.banner.reconcile([{ accountId: 'account-a', enabled: false }]);
  assert.equal(f.values.get('mailBannerAccountId'), '');
  assert.equal(f.values.has('mailNotificationAccountId'), false);
  f.banner.showInboxArrival('account-b', 1); f.banner.reconcile([]);
  assert.equal(f.values.get('mailBannerAccountId'), '');
});
