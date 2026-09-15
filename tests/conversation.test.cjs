const { test } = require('node:test');
const assert = require('node:assert/strict');
const { conversationGroups, conversationMessages, stableMessageKey } = require('../.tools/test-output/mail/Conversation.js');
function mail(id, options = {}) {
  return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds: ['inbox'], keywords: [],
    from: [], to: [], replyTo: [], subject: 'Routine update', preview: '', receivedAt: 100,
    hasAttachment: false, textBody: null, htmlBody: null, hasHtmlBody: false,
    bodyTruncated: false, bodyEncodingProblem: false, ...options };
}
const ids = messages => messages.map(message => message.id);

test('Message preferences follow moved and duplicate copies but not replies or ambiguous identities', () => {
  const first = mail('inbox-copy', { messageIds: ['<shared@EXAMPLE.TEST>'] });
  const moved = mail('archive-copy', { messageIds: ['shared@example.test'] });
  assert.equal(stableMessageKey(first), stableMessageKey(moved));
  assert.notEqual(stableMessageKey(first), stableMessageKey(mail('reply', { references: first.messageIds })));
  assert.equal(stableMessageKey(mail('no-id', { messageIds: [] })), 'copy:no-id');
  assert.equal(stableMessageKey(mail('ambiguous', { messageIds: ['a@example.test', 'b@example.test'] })), 'copy:ambiguous');
});

test('References and In-Reply-To connect received and sent mail oldest first despite renamed subjects', () => {
  const root = mail('received', { receivedAt: 10, textBody: 'Original' });
  const sent = mail('sent', { receivedAt: 20, mailboxIds: ['sent'], subject: 'Renamed reply', inReplyTo: ['<received@example.test>'] });
  const reply = mail('reply', { receivedAt: 30, references: ['<received@example.test> <sent@example.test>'] });
  const unrelated = mail('unrelated', { subject: 'Routine update' });
  assert.deepEqual(ids(conversationMessages(sent, [reply, unrelated, root, sent])), ['received', 'sent', 'reply']);
  assert.deepEqual(conversationGroups([reply, unrelated, root, sent]).map(ids), [['received', 'sent', 'reply'], ['unrelated']]);
});

test('Shared uncached ancestors and meaningful native thread IDs connect messages without subject guessing', () => {
  const first = mail('a', { references: ['missing@example.test'], receivedAt: 1 });
  const second = mail('b', { inReplyTo: ['missing@example.test'], receivedAt: 2 });
  const native = mail('c', { threadId: 'native-thread', receivedAt: 3 });
  const nativeReply = mail('d', { threadId: 'native-thread', receivedAt: 4 });
  const placeholder = mail('e');
  const misleading = mail('f', { threadId: 'e' });
  assert.deepEqual(conversationGroups([second, nativeReply, first, native, placeholder, misleading]).map(ids),
    [['a', 'b'], ['c', 'd'], ['e'], ['f']]);
});

test('Duplicate Sent folder copies use a complete body but the selected reader retains its exact copy', () => {
  const inboxCopy = mail('inbox-copy', { messageIds: ['shared@example.test'], receivedAt: 10 });
  const sentCopy = mail('sent-copy', { messageIds: ['<shared@EXAMPLE.TEST>'], mailboxIds: ['sent'], receivedAt: 10,
    textBody: 'Saved Sent body', htmlBody: '<p>Saved Sent body</p>', hasHtmlBody: true });
  const partialCopy = mail('partial-copy', { messageIds: ['shared@example.test'], textBody: 'Partial', bodyTruncated: true, receivedAt: 10 });
  const reply = mail('reply', { inReplyTo: ['shared@example.test'], receivedAt: 20 });
  const source = [inboxCopy, reply, partialCopy, sentCopy];
  assert.deepEqual(ids(conversationGroups(source)[0]), ['sent-copy', 'reply']);
  const selected = conversationMessages(inboxCopy, source);
  assert.deepEqual(ids(selected), ['inbox-copy', 'reply']);
  assert.equal(selected[0], inboxCopy);
  assert.deepEqual(selected[0].mailboxIds, ['inbox']);
  assert.equal(inboxCopy.textBody, null);
  assert.deepEqual(ids(conversationMessages(sentCopy, source)), ['sent-copy', 'reply']);
});

test('Truncated, malformed and control-containing references do not join unrelated subjects', () => {
  const original = mail('root');
  const fragments = [
    '<root@example.test', 'root@example.test>', 'root@', 'root example.test', 'root@exa\u0000mple.test',
    'x'.repeat(17000) + '<root@example.test>'
  ].map((value, index) => mail(`fragment-${index}`, { references: [value] }));
  assert.equal(conversationGroups([original, ...fragments]).length, fragments.length + 1);
  const recovered = mail('valid-part', { references: ['<root@example.test> <unfinished@'] });
  assert.deepEqual(ids(conversationMessages(original, [recovered])), ['root', 'valid-part']);
});

test('Duplicate identities and cyclic references are stable under shuffled inputs and do not mutate mail', () => {
  const a = mail('a', { messageIds: ['one@example.test', 'alias@example.test'], inReplyTo: ['two@example.test'], receivedAt: 10 });
  const b = mail('b', { messageIds: ['alias@example.test'], receivedAt: 10 });
  const c = mail('c', { messageIds: ['two@example.test'], references: ['one@example.test'], receivedAt: 10 });
  const source = JSON.stringify([a, b, c]);
  for (const order of [[a, b, c], [c, b, a], [b, a, c]]) {
    assert.deepEqual(conversationGroups(order).map(ids), [['a', 'c']]);
  }
  assert.equal(JSON.stringify([a, b, c]), source);
  assert.deepEqual(conversationGroups([]), []);
});

test('Unindexed anchors and separate account indexes remain isolated even with reused native IDs', () => {
  const alpha = mail('same-id', { textBody: 'Alpha private cached body' });
  const beta = mail('same-id', { textBody: 'Beta private cached body' });
  assert.deepEqual(conversationMessages(alpha, []), [alpha]);
  assert.deepEqual(conversationMessages(alpha, [alpha]), [alpha]);
  assert.deepEqual(conversationMessages(beta, [beta]), [beta]);
  assert.equal(conversationGroups([alpha])[0][0].textBody, alpha.textBody);
  assert.equal(conversationGroups([beta])[0][0].textBody, beta.textBody);
});

test('Metadata-only conversation indexes preserve the preferred downloaded copy without carrying its HTML', () => {
  const inboxCopy = mail('inbox-copy', { messageIds: ['shared@example.test'], receivedAt: 10 });
  const saved = mail('sent-copy', { messageIds: ['shared@example.test'], mailboxIds: ['sent'], receivedAt: 20,
    cachedBodyAvailable: true, hasHtmlBody: true });
  const projected = conversationGroups([inboxCopy, saved])[0];
  assert.deepEqual(ids(projected), ['sent-copy']);
  assert.equal(projected[0].htmlBody, null);
  assert.deepEqual(ids(conversationMessages(inboxCopy, [inboxCopy, saved])), ['inbox-copy']);
});
