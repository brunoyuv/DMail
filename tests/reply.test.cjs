const { test } = require('node:test');
const assert = require('node:assert/strict');
const { replyContent } = require('../.tools/test-output/mail/smtp/Reply.js');
function mail(overrides = {}) {
  const address = email => ({ name: '', email });
  return { id: 'one', threadId: 'one', messageIds: ['<parent@example.test>'], mailboxIds: ['inbox'], keywords: [],
    from: [address('sender@example.test')], replyTo: [address('list@example.test')],
    to: [address('me@example.test'), address('recipient@example.test')], cc: [address('copy@example.test'), address('RECIPIENT@example.test')],
    inReplyTo: ['grandparent@example.test'], references: ['<root@example.test>', 'grandparent@example.test'],
    subject: 'Meeting', textBody: 'Hello\r\n日本語', receivedAt: 1000, preview: '', hasAttachment: false,
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false, ...overrides };
}
test('Reply targets Reply-To, quotes readable text and links the parent and ancestry', () => {
  const result = replyContent(mail(), 'me@example.test', false);
  assert.equal(result.to, 'list@example.test'); assert.equal(result.cc, '');
  assert.equal(result.subject, 'Re: Meeting'); assert.match(result.text, /> Hello\n> 日本語/);
  assert.deepEqual(result.inReplyTo, ['parent@example.test']);
  assert.deepEqual(result.references, ['root@example.test', 'grandparent@example.test', 'parent@example.test']);
});
test('Reply all excludes the current identity and deduplicates across To and Cc without including Bcc', () => {
  const result = replyContent(mail({ bcc: [{ name: '', email: 'hidden@example.test' }] }), 'ME@example.test', true);
  assert.equal(result.to, 'list@example.test, recipient@example.test'); assert.equal(result.cc, 'copy@example.test');
  assert.ok(!JSON.stringify(result).includes('hidden@example.test'));
});
test('Reply to a sent message targets its recipients, and old cached records still work', () => {
  const result = replyContent(mail({ replyTo: [], from: [{ name: '', email: 'me@example.test' }], cc: undefined, references: undefined, inReplyTo: undefined, subject: 'Re: Meeting' }), 'me@example.test', true);
  assert.equal(result.to, 'recipient@example.test'); assert.equal(result.cc, '');
  assert.equal(result.subject, 'Re: Meeting'); assert.deepEqual(result.references, ['parent@example.test']);
});
test('Untrusted recipient delimiters are rejected and invalid message IDs cannot inject headers', () => {
  assert.throws(() => replyContent(mail({ replyTo: [{ name: '', email: 'good@example.test, bad@example.test' }] }), 'me@example.test', false));
  const result = replyContent(mail({ messageIds: ['parent@example.test\r\nBcc: injected@example.test'], references: ['<root@example.test>'], subject: 'Meeting\r\nBcc: bad' }), 'me@example.test', false);
  assert.deepEqual(result.inReplyTo, []); assert.equal(result.subject.includes('\n'), false);
});
test('Long thread ancestry and quoted text are bounded without losing the root or parent', () => {
  const result = replyContent(mail({ references: Array.from({length: 120}, (_, i) => `m${i}@example.test`), textBody: '字'.repeat(35000) }), 'me@example.test', false);
  assert.equal(result.references.length, 100); assert.equal(result.references[0], 'm0@example.test');
  assert.equal(result.references.at(-1), 'parent@example.test'); assert.match(result.text, /Quoted message truncated/); assert.ok(result.text.length < 60000);
  assert.ok(replyContent(mail({textBody: '\n'.repeat(35000)}), 'me@example.test', false).text.length < 60000);
});
const { forwardContent } = require('../.tools/test-output/mail/smtp/Reply.js');
test('Forward starts without recipients or threading and quotes original visible headers and text', () => {
  const result = forwardContent(mail({ bcc: [{name: '', email: 'hidden@example.test'}] }));
  assert.equal(result.subject, 'Fwd: Meeting'); assert.equal(result.to, ''); assert.equal(result.cc, '');
  assert.deepEqual(result.inReplyTo, []); assert.deepEqual(result.references, []);
  assert.match(result.text, /Forwarded message/); assert.match(result.text, /Hello\n日本語/);
  assert.ok(!JSON.stringify(result).includes('hidden@example.test'));
  assert.equal(forwardContent(mail({subject: 'Fwd: Meeting'})).subject, 'Fwd: Meeting');
});
test('HTML forwards preserve markup, escape metadata and surface omitted attachment/truncation information', () => {
  const result = forwardContent(mail({textBody: undefined, htmlBody: '<b>HTML only 日本語</b>', subject: '<img src=x>', hasAttachment: true, bodyTruncated: true}));
  assert.equal(result.text, ''); assert.match(result.forwardHtml, /<b>HTML only 日本語<\/b>/);
  assert.match(result.forwardHtml, /Subject: &lt;img src=x&gt;/);
  assert.match(result.forwardWarning, /Attachments are not included/); assert.match(result.forwardWarning, /downloaded portion/);
});
test('Forward does not silently truncate oversized bodies or produce invalid subject headers', () => {
  assert.throws(() => forwardContent(mail({textBody: 'x'.repeat(50001)})), /forwardTooLarge/);
  assert.throws(() => forwardContent(mail({htmlBody: 'x'.repeat(100001)})), /forwardTooLarge/);
  const value = forwardContent(mail({subject: 'hello\r\nBcc: injected'}));
  assert.equal(value.subject.includes('\n'), false);
});
