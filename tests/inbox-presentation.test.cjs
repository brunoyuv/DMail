const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');

const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const methods = ['mailRowKey', 'conversationCount', 'updateSearchPosition', 'inboxBlocked'].map(name => {
  const match = source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`));
  assert.ok(match, name); return match[0];
});
const code = ts.transpileModule(`export class InboxPresentation { ${methods.join('\n')} }`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
function fixture() {
  const module = { exports: {} };
  new Function('module', 'exports', code)(module, module.exports);
  let offset = 0;
  const ui = new module.exports.InboxPresentation();
  Object.assign(ui, { account: { id: 'synthetic-account' }, conversationById: new Map(),
    inboxScrollActive: false, inboxPullActive: false, swipeClosing: false, inboxSwipes: new Set(),
    searchVisible: false, searchInteracted: false, busy: false, changing: false, refreshing: false, mailboxRefreshActive: false,
    paths: { getAllPathName: () => [] }, mailScroller: { currentOffset: () => ({ yOffset: offset }) } });
  return { ui, scrollTo: value => { offset = value; } };
}
function message() {
  return { id: 'message', from: [{ name: 'Sender', email: 'sender@example.test' }],
    subject: 'Synthetic subject', preview: 'Saved summary', receivedAt: 123,
    keywords: [], mailboxIds: ['inbox'], maySetSeen: true, maySetKeywords: true };
}

test('Body downloads and nonvisual metadata preserve the native row identity without reading large bodies', () => {
  const { ui } = fixture(), mail = message(), original = ui.mailRowKey(mail);
  Object.defineProperty(mail, 'htmlBody', { get() { throw new Error('The row must not inspect HTML bytes'); } });
  Object.defineProperty(mail, 'textBody', { get() { throw new Error('The row must not inspect body bytes'); } });
  mail.threadId = 'new-thread'; mail.messageIds = ['new@example.test']; mail.attachments = [{ name: 'file.pdf' }];
  assert.equal(ui.mailRowKey(mail), original);
  ui.account.id = 'another-account'; assert.notEqual(ui.mailRowKey(mail), original);
});

test('Actual row text, read/star state and conversation count still invalidate their displayed row', () => {
  const { ui } = fixture(), original = ui.mailRowKey(message());
  for (const change of [
    { preview: 'A newly downloaded summary' }, { subject: 'Updated subject' },
    { from: [{ name: 'Different sender', email: 'sender@example.test' }] },
    { keywords: ['$seen'] }, { keywords: ['$flagged'] }, { maySetSeen: false }
  ]) assert.notEqual(ui.mailRowKey({ ...message(), ...change }), original);
  ui.conversationById.set('message', [message(), { ...message(), id: 'reply' }]);
  assert.notEqual(ui.mailRowKey(message()), original);
});

test('Search remains stable during drag, pull and swipe, then follows the settled scroll position', () => {
  const { ui, scrollTo } = fixture();
  ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
  ui.searchInteracted = true;
  for (const state of ['inboxScrollActive', 'inboxPullActive', 'swipeClosing', 'mailboxRefreshActive']) {
    ui[state] = true; ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
    assert.equal(ui.inboxBlocked(), true); ui[state] = false;
  }
  ui.inboxSwipes.add('message'); ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
  ui.inboxSwipes.clear(); ui.updateSearchPosition(); assert.equal(ui.searchVisible, true);
  scrollTo(180); ui.inboxScrollActive = true;
  ui.updateSearchPosition(); assert.equal(ui.searchVisible, true);
  ui.inboxScrollActive = false; ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
  scrollTo(0); ui.inboxPullActive = true; ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
  ui.inboxPullActive = false; ui.updateSearchPosition(); assert.equal(ui.searchVisible, true);
});

test('A hidden native refresh spinner cannot reveal or collapse search while its mailbox request remains active', () => {
  const { ui, scrollTo } = fixture(); ui.searchInteracted = true; ui.mailboxRefreshActive = true; ui.refreshing = false;
  ui.updateSearchPosition(); assert.equal(ui.searchVisible, false); assert.equal(ui.inboxBlocked(), true);
  ui.searchVisible = true; scrollTo(180); ui.updateSearchPosition(); assert.equal(ui.searchVisible, true);
  ui.mailboxRefreshActive = false; ui.updateSearchPosition(); assert.equal(ui.searchVisible, false);
  assert.equal(ui.inboxBlocked(), false); scrollTo(0); ui.updateSearchPosition(); assert.equal(ui.searchVisible, true);
});
