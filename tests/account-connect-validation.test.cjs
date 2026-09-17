// SPDX-License-Identifier: MPL-2.0
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['connectionNotice', 'probe'].map(name => source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');
const compiled = ts.transpileModule(`class Host { ${methods} }; return Host;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
function fixture(overrides = {}) {
  const calls = { dialogs: [], connections: 0, saves: 0 };
  const Host = new Function('validateEmailAddress', 'TokenCredentials', compiled)(email => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email), class {});
  const host = Object.assign(new Host(), {
    busy: false, ready: true, protocol: 'imap', serverUrl: 'imap.example.test', token: 'synthetic-password',
    username: 'user', emailAddress: 'user@example.test', generation: 0, error: '', candidates: [],
    label: key => key, getUIContext: () => ({ showAlertDialog: d => calls.dialogs.push(d) }),
    endpoint: () => 'imaps://imap.example.test:993', secret: () => 'synthetic-secret',
    clientFactory: { create: () => { calls.connections++; return { connect: async () => ({ accounts: [{ id: 'synthetic' }] }) }; } },
    saveAccount: async () => { calls.saves++; }, showError: () => assert.fail('Unexpected network error'), ...overrides
  });
  return { host, calls };
}
test('Incomplete IMAP details show a dismissible notice without contacting a server or changing accounts', async () => {
  for (const [field, value] of [['emailAddress', '  '], ['username', '  '], ['serverUrl', '  '], ['token', '']]) {
    const { host, calls } = fixture({ [field]: value }); await host.probe();
    assert.equal(calls.connections, 0); assert.equal(calls.saves, 0); assert.equal(host.generation, 0);
    assert.equal(calls.dialogs[0].message, 'imap_account_details_required'); calls.dialogs[0].confirm.action();
    assert.equal(calls.connections, 0);
  }
});
test('JMAP asks for server and token but does not require IMAP-only fields', async () => {
  for (const missing of [{ serverUrl: ' ' }, { token: '' }]) {
    const { host, calls } = fixture({ protocol: 'jmap', ...missing }); await host.probe();
    assert.equal(calls.dialogs[0].message, 'jmap_account_details_required'); assert.equal(calls.connections, 0);
  }
  const { host, calls } = fixture({ protocol: 'jmap', username: '', emailAddress: '' }); await host.probe();
  assert.equal(calls.connections, 1); assert.equal(calls.saves, 1); assert.equal(calls.dialogs.length, 0);
});
test('An invalid email or unavailable storage cannot reach the network', async () => {
  for (const [overrides, message] of [[{ emailAddress: 'invalid' }, 'imap_email_invalid'], [{ ready: false }, 'account_storage_error']]) {
    const { host, calls } = fixture(overrides); await host.probe();
    assert.equal(calls.dialogs[0].message, message); assert.equal(calls.connections, 0);
  }
});
test('Complete IMAP form connects once and repeated taps while busy are ignored', async () => {
  const { host, calls } = fixture(); const pending = host.probe(); await host.probe(); await pending;
  assert.equal(calls.connections, 1); assert.equal(calls.saves, 1); assert.equal(calls.dialogs.length, 0); assert.equal(host.busy, false);
});
