const { test } = require('node:test');
const assert = require('node:assert/strict');
const { sentMailbox, sentMessage, prependSentMessage, sendFailureState, sendFailureLabel, sentCompletionLabel } = require('../.tools/test-output/mail/smtp/SentMail.js');
const { cacheEmail, cacheReadyForReading } = require('../.tools/test-output/data/MailCacheModel.js');

const draft = { id: '00000000-0000-0000-0000-000000000001', to: 'alice@example.test; bob@example.test',
  cc: 'carol@example.test', subject: 'Re: café 中文 😀', inReplyTo: ['parent@example.test'], references: ['root@example.test', 'parent@example.test'] };
const submitted = { accepted: true, messageId: '<sent@example.test>', date: Date.now(),
  textBody: 'My new reply\n\n> Previous reply café 中文 😀', htmlBody: '<p>My new reply</p><blockquote>Previous reply café 中文 😀</blockquote>', sentCopy: 'saved', sentMailboxId: 'sent_box' };
const box = { id: 'sent_box', name: 'Sent Messages', role: 'sent', parentId: null, sortOrder: 2,
  totalEmails: 20, unreadEmails: 0, countsKnown: true, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true };

test('Confirmed SMTP output creates an immediately readable offline Sent message with reply ancestry and exact bodies', () => {
  const mail = sentMessage('sender@example.test', draft, submitted, box.id);
  assert.deepEqual(mail.messageIds, ['sent@example.test']);
  assert.deepEqual(mail.mailboxIds, [box.id]);
  assert.deepEqual(mail.keywords, ['$seen']);
  assert.deepEqual(mail.to.map(value => value.email), ['alice@example.test', 'bob@example.test']);
  assert.deepEqual(mail.cc.map(value => value.email), ['carol@example.test']);
  assert.deepEqual(mail.references, draft.references);
  assert.deepEqual(mail.inReplyTo, draft.inReplyTo);
  assert.equal(mail.textBody, submitted.textBody); assert.equal(mail.htmlBody, submitted.htmlBody);
  assert.equal(mail.receivedAt, submitted.date); assert.equal(mail.subject, draft.subject);
  assert.equal(cacheReadyForReading(cacheEmail(mail, true, null, submitted.date), submitted.date), true);
  assert.equal(mail.maySetSeen, false); assert.equal(mail.maySetKeywords, false);
});

test('A Sent-copy failure preserves accepted mail locally and never converts success into a resendable draft', () => {
  for (const status of ['server', 'saved', 'failed', 'unconfirmed']) {
    const mail = sentMessage('sender@example.test', draft, { ...submitted, sentCopy: status }, box.id);
    assert.ok(mail.id.startsWith('local_sent_'));
    assert.equal(mail.textBody, submitted.textBody);
    assert.equal(sentCompletionLabel(status), status === 'server' || status === 'saved' ? 'sent' : `sent_copy_${status}`);
  }
  assert.throws(() => sentMessage('sender@example.test', draft, { ...submitted, accepted: false }, box.id));
  assert.throws(() => sentMessage('sender@example.test', draft, { ...submitted, messageId: '' }, box.id));
});

test('Confirmed cached Sent retains the draft sender name independently from its mailbox address', () => {
  const mail = sentMessage('sender@example.test', { ...draft, senderName: '李明 / Zoë 📬' }, submitted, box.id);
  assert.deepEqual(mail.from, [{ name: '李明 / Zoë 📬', email: 'sender@example.test' }]);
  assert.deepEqual(sentMessage('sender@example.test', draft, submitted, box.id).from,
    [{ name: '', email: 'sender@example.test' }]);
});

test('Sent chooses the actual server destination and never mistakes the legacy local folder for it', () => {
  const known = sentMailbox([box], submitted);
  assert.deepEqual(known, box); assert.notEqual(known, box);
  assert.deepEqual(sentMailbox([box], { ...submitted, sentMailboxId: undefined, sentCopy: 'server' }), box);
  const discovered = sentMailbox([], submitted);
  assert.equal(discovered.id, 'sent_box'); assert.equal(discovered.role, 'sent');
  const local = sentMailbox([], { ...submitted, sentMailboxId: undefined, sentCopy: 'failed' });
  assert.equal(local.id, 'local_sent'); assert.equal(local.role, null);
  assert.equal(local.mayRemoveItems, false); assert.equal(local.countsKnown, false);
  const legacy = { ...local, role: 'sent' };
  assert.deepEqual(sentMailbox([legacy, box], { ...submitted, sentMailboxId: undefined, sentCopy: 'server' }), box);
});

test('Local Sent insertion retains older messages and deduplicates the same submission without sacrificing offline body availability', () => {
  const mail = sentMessage('sender@example.test', draft, submitted, box.id);
  const older = { ...mail, id: 'older', messageIds: ['older@example.test'], textBody: 'Older downloaded body' };
  const original = [older];
  assert.deepEqual(prependSentMessage(mail, original), [mail, older]);
  assert.deepEqual(original, [older]);
  assert.deepEqual(prependSentMessage(mail, [mail, older]), [mail, older]);
  const summary = { ...mail, id: 'server_id', messageIds: ['<sent@example.test>'], textBody: null, htmlBody: null };
  assert.deepEqual(prependSentMessage(mail, [summary, older]), [mail, older]);
  const server = { ...summary, textBody: submitted.textBody, htmlBody: submitted.htmlBody };
  assert.deepEqual(prependSentMessage(mail, [server, older]), [server, older]);
});

test('Only an uncertain attempted delivery requires manual reconciliation; preflight failures remain editable', () => {
  assert.equal(sendFailureState(false, undefined), 'draft');
  assert.equal(sendFailureState(false, 'deliveryUnconfirmed'), 'draft');
  assert.equal(sendFailureState(true, undefined), 'unconfirmed');
  assert.equal(sendFailureState(true, 'deliveryUnconfirmed'), 'unconfirmed');
  for (const code of ['rejected', 'authenticationRequired', 'certificate', 'unsafeEndpoint', 'network']) {
    assert.equal(sendFailureState(true, code), 'draft');
  }
  assert.equal(sendFailureLabel('unconfirmed', 'deliveryUnconfirmed'), 'delivery_uncertain');
  assert.equal(sendFailureLabel('draft', 'rejected'), 'smtp_rejected');
  assert.equal(sendFailureLabel('draft', 'authenticationRequired'), 'smtp_auth_error');
  assert.equal(sendFailureLabel('draft', 'invalidMessage'), 'send_invalid');
});
