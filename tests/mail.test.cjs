const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Mail, MailSnapshot, Folder, copyMail, selectMail, updateMail, replyDraft, hasDraftContent, validSnapshot } = require('../.tools/test-output/model/Mail.js');

function message(id, folder = Folder.Inbox) {
  const mail = new Mail();
  mail.id = id;
  mail.folder = folder;
  mail.receivedAt = 100;
  return mail;
}

test('search respects mailbox, unread filter, whitespace and case', () => {
  const inbox = message('inbox');
  inbox.fromName = 'Alex Chen'; inbox.unread = true;
  const archive = message('archive', Folder.Archive);
  archive.subject = 'Alex';
  assert.deepEqual(selectMail([archive, inbox], Folder.Inbox, ' ALEX ', true).map(m => m.id), ['inbox']);
  assert.equal(selectMail([archive, inbox], Folder.Inbox, 'missing', false).length, 0);
});

test('starred is a virtual folder and excludes drafts', () => {
  const archived = message('archive', Folder.Archive); archived.starred = true;
  const draft = message('draft', Folder.Drafts); draft.starred = true;
  assert.deepEqual(selectMail([draft, archived], Folder.Starred, '', false).map(m => m.id), ['archive']);
});

test('sorting and updates do not mutate previous state or draft references', () => {
  const original = message('one');
  const later = message('two'); later.receivedAt = 200;
  const rows = [original, later];
  assert.equal(selectMail(rows, Folder.Inbox, '', false)[0].id, 'two');
  assert.equal(rows[0].id, 'one');
  const changed = copyMail(original); changed.unread = true;
  const updated = updateMail(rows, changed);
  changed.subject = 'typing';
  assert.equal(updated[0].subject, '');
  assert.equal(original.unread, false);
  assert.equal(updated.length, 2);
  assert.equal(updateMail(rows, message('three')).length, 3);
});

test('reply preserves thread, recipient and one Re prefix', () => {
  const source = message('one'); source.threadId = 'server-thread';
  source.fromAddress = 'alex@example.com'; source.subject = 'Hello';
  const reply = replyDraft(source, 'draft-id', 300);
  assert.equal(reply.to, 'alex@example.com');
  assert.equal(reply.subject, 'Re: Hello');
  assert.equal(reply.threadId, 'server-thread');
  assert.equal(reply.folder, Folder.Drafts);
  assert.equal(replyDraft(reply, 'second', 400).subject, 'Re: Hello');
});

test('empty drafts are not persisted, incomplete drafts are retained', () => {
  const draft = message('draft', Folder.Drafts);
  draft.body = '  \n ';
  assert.equal(hasDraftContent(draft), false);
  draft.to = 'unfinished@';
  assert.equal(hasDraftContent(draft), true);
});

test('storage round-trip validates schema and rejects corruption without reset', () => {
  const snapshot = new MailSnapshot(); snapshot.messages = [message('one')];
  assert.equal(validSnapshot(JSON.parse(JSON.stringify(snapshot))), true);
  assert.equal(validSnapshot({ version: 2, messages: [] }), false);
  assert.equal(validSnapshot({ version: 1, messages: [null] }), false);
  assert.equal(validSnapshot({ version: 1, messages: [{ id: 'partial' }] }), false);
  snapshot.messages.push(message('one'));
  assert.equal(validSnapshot(snapshot), false);
  snapshot.messages = [message('one', Folder.Starred)];
  assert.equal(validSnapshot(snapshot), false);
});
