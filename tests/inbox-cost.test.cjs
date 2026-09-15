// Work counters exercise the actual UI method; no wall-clock performance thresholds.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const method = source.match(/  private visibleEmails\([\s\S]*?\n  }/)[0];
const code = ts.transpileModule(`class Inbox { ${method} }; return Inbox;`, { compilerOptions: { target: ts.ScriptTarget.ES2021 } }).outputText;
const Inbox = new Function('MailOperations', code)({ overlay: (_account, mail) => mail });
function mail(id, seen = true, mailbox = 'inbox') {
 return { id, messageIds: [id + '@example.test'], subject: id, preview: 'Preview', from: [],
  mailboxIds: [mailbox], keywords: seen ? ['$seen'] : [] };
}
function inbox(emails, groups = new Map()) {
 return Object.assign(new Inbox(), { emails, conversationById: groups, account: { id: 'a' }, mailboxId: 'inbox', query: '', unreadOnly: false });
}
test('Unthreaded inbox filtering performs linear identity work instead of rescanning every row', () => {
 const messages = []; let reads = 0;
 for (let i = 0; i < 2000; i++) {
  const value = mail('mail-' + i), id = value.id;
  Object.defineProperty(value, 'id', { get() { reads++; return id; } }); messages.push(value);
 }
 const result = inbox(messages).visibleEmails();
 assert.equal(result.length, 2000);
 assert.ok(reads <= messages.length * 12, `Expected linear identity work, got ${reads} reads`);
});
test('Threaded folder filtering preserves order, unread selection, sent-header search and copied identities', () => {
 const recent = mail('recent'), old = mail('old', false), copy = mail('copied', false), other = mail('other'), sent = mail('sent', true, 'sent');
 copy.messageIds = old.messageIds; sent.subject = 'Unique conversation words';
 const thread = [recent, old, sent], groups = new Map([[recent.id, thread], [old.id, thread], [copy.id, thread]]);
 const ui = inbox([recent, other, copy, old, sent], groups);
 assert.deepEqual(ui.visibleEmails().map(x => x.id), ['recent', 'other']);
 ui.unreadOnly = true; assert.deepEqual(ui.visibleEmails().map(x => x.id), ['copied']);
 ui.query = 'UNIQUE conversation'; assert.deepEqual(ui.visibleEmails().map(x => x.id), ['copied']);
 ui.query = 'absent'; assert.deepEqual(ui.visibleEmails(), []);
});
test('Nonmatching large threads only evaluate their members once per rendering pass', () => {
 let searches = 0;
 const messages = Array.from({ length: 1500 }, (_, i) => {
  const value = mail('mail-' + i);
  Object.defineProperty(value, 'subject', { get() { searches++; return 'Ordinary subject'; } }); return value;
 });
 const ui = inbox(messages, new Map(messages.map(value => [value.id, messages]))); ui.query = 'absent';
 assert.deepEqual(ui.visibleEmails(), []);
 assert.equal(searches, messages.length);
});
