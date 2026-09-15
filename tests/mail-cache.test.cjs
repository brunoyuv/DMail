const { test } = require('node:test');
const assert = require('node:assert/strict');
const { cacheEmail, decodeCachedEmail, decodeCachedView, decodeCachedBoxes } = require('../.tools/test-output/data/MailCacheModel.js');
function mail() {
  return { id: 'e1', threadId: 't1', mailboxIds: ['inbox', 'label'], keywords: [], messageIds: [],
    from: [], to: [], replyTo: [], subject: 'Cached', preview: 'Preview', receivedAt: -1000, hasAttachment: false,
    textBody: 'Body 鸿蒙 📬', bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: false };
}
test('Cache round-trip preserves body, identifiers and pre-1970 message dates without aliasing', () => {
  const source = mail(); const cached = cacheEmail(source, true, null, 100);
  source.mailboxIds.pop(); source.textBody = 'changed';
  assert.deepEqual(decodeCachedEmail(JSON.stringify(cached)), cached);
  assert.deepEqual(cached.mail.mailboxIds, ['inbox', 'label']);
  assert.equal(cached.mail.textBody, 'Body 鸿蒙 📬');
  assert.equal(cached.bodySavedAt, 100);
});
test('Fresh summary updates mutable headers and flags while preserving a downloaded immutable body', () => {
  const before = cacheEmail(mail(), true, null, 100);
  const summary = { ...mail(), textBody: null, keywords: ['$seen'], mailboxIds: ['archive', 'label'] };
  const after = cacheEmail(summary, false, before, 200);
  assert.equal(after.mail.textBody, before.mail.textBody);
  assert.equal(after.bodySavedAt, 100); assert.equal(after.savedAt, 200);
  assert.deepEqual(after.mail.keywords, ['$seen']); assert.deepEqual(after.mail.mailboxIds, ['archive', 'label']);
  assert.equal(before.mail.keywords.length, 0);
});
test('Header refreshes preserve a downloaded preview and offline decoding recovers old blank summaries', () => {
  const before = cacheEmail({ ...mail(), preview: 'Downloaded summary 中文' }, true, null, 100);
  const summary = { ...mail(), preview: '', textBody: null };
  const after = cacheEmail(summary, false, before, 200);
  assert.equal(after.mail.preview, 'Downloaded summary 中文'); assert.equal(after.bodySavedAt, 100);
  const old = { ...before, mail: { ...before.mail, preview: '', textBody: '  Cached\n body 中文 😀  ' } };
  assert.equal(decodeCachedEmail(JSON.stringify(old)).mail.preview, 'Cached body 中文 😀');
  assert.equal(cacheEmail({ ...summary, id: 'other' }, false, before, 200).mail.preview, '');
});
test('HTML-only cached bodies provide text summaries without CSS, scripts, or network access', () => {
  const html = { ...mail(), preview: '', textBody: null, hasHtmlBody: true,
    htmlBody: '<head><style>body { color: red }</style></head><script>secretScript()</script><p>Hello&nbsp;中文 &#x1f600;</p><p>A &amp; B</p>' };
  assert.equal(cacheEmail(html, true, null, 100).mail.preview, 'Hello 中文 😀 A & B');
  const bounded = cacheEmail({ ...mail(), preview: '', textBody: '😀'.repeat(250) }, true, null, 100).mail.preview;
  assert.equal(Array.from(bounded).length, 180);
});
test('Cache distinguishes never-downloaded and HTML-only bodies and cannot reuse another message body', () => {
  const summary = { ...mail(), textBody: null };
  assert.equal(cacheEmail(summary, false, null, 100).bodySavedAt, null);
  const html = cacheEmail({ ...summary, hasHtmlBody: true }, true, null, 100);
  assert.equal(html.mail.textBody, null); assert.equal(html.bodySavedAt, 100);
  const other = cacheEmail({ ...summary, id: 'other' }, false, html, 200);
  assert.equal(other.bodySavedAt, null); assert.equal(other.mail.hasHtmlBody, false);
});
test('Cache rejects corrupt records and unsupported versions instead of returning unchecked mail', () => {
  const base = cacheEmail(mail(), true, null, 100);
  for (const mutate of [x => x.version = 9, x => x.savedAt = -1, x => x.bodySavedAt = 'now',
    x => x.mail.mailboxIds.push('inbox'), x => x.mail.receivedAt = 'yesterday', x => x.mail.from = [{}],
    x => delete x.mail.bodyTruncated, x => x.mail.textBody = {}]) {
    const value = JSON.parse(JSON.stringify(base)); mutate(value);
    assert.throws(() => decodeCachedEmail(JSON.stringify(value)), /Invalid mail cache/);
  }
});
test('Cache validates mailbox view identifiers and folder metadata', () => {
  const view = { version: 1, savedAt: 100, mailboxId: 'inbox', ids: ['e1', 'e2'] };
  assert.deepEqual(decodeCachedView(JSON.stringify(view)), view);
  assert.throws(() => decodeCachedView(JSON.stringify({ ...view, ids: ['e1', 'e1'] })));
  assert.deepEqual(decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: 100, boxes: [] })).boxes, []);
  assert.throws(() => decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: 100, boxes: [{ id: 'inbox' }] })));
});

test('Cached pagination and account permissions survive serialization with old records still readable', () => {
  const oldView = { version: 1, savedAt: 100, mailboxId: 'inbox', ids: ['e1'] };
  assert.equal(decodeCachedView(JSON.stringify(oldView)).nextPosition, undefined);
  assert.equal(decodeCachedView(JSON.stringify(oldView)).queryState, undefined);
  const page = { ...oldView, nextPosition: 40, queryState: 'opaque:query-state/1' };
  assert.deepEqual(decodeCachedView(JSON.stringify(page)), page);
  assert.equal(decodeCachedView(JSON.stringify({ ...page, nextPosition: null })).nextPosition, null);
  const boxes = { version: 1, savedAt: 100, boxes: [] };
  assert.equal(decodeCachedBoxes(JSON.stringify(boxes)).readOnly, undefined);
  for (const readOnly of [true, false]) {
    assert.equal(decodeCachedBoxes(JSON.stringify({ ...boxes, readOnly })).readOnly, readOnly);
  }
});

test('Cached pagination and account permissions reject malformed optional metadata', () => {
  const page = { version: 1, savedAt: 100, mailboxId: 'inbox', ids: ['e1'] };
  for (const nextPosition of [-1, 0.5, '40', Number.MAX_SAFE_INTEGER + 1, {}]) {
    assert.throws(() => decodeCachedView(JSON.stringify({ ...page, nextPosition })), /Invalid mail cache/);
  }
  for (const queryState of [null, 42, {}, []]) {
    assert.throws(() => decodeCachedView(JSON.stringify({ ...page, queryState })), /Invalid mail cache/);
  }
  for (const readOnly of [null, 'false', 0, {}, []]) {
    assert.throws(() => decodeCachedBoxes(JSON.stringify({ version: 1, savedAt: 100, boxes: [], readOnly })), /Invalid mail cache/);
  }
});
test('HTML bodies survive summary refreshes and old cache records still open', () => {
  const source = { ...mail(), htmlBody: '<h1>HTML 鸿蒙</h1>', hasHtmlBody: true };
  const before = cacheEmail(source, true, null, 100);
  const summary = { ...mail(), textBody: null, htmlBody: null };
  assert.equal(cacheEmail(summary, false, before, 200).mail.htmlBody, source.htmlBody);
  assert.equal(decodeCachedEmail(JSON.stringify(cacheEmail(mail(), true, null, 100))).mail.htmlBody, undefined);
  const invalid = { ...before, mail: { ...source, htmlBody: {} } };
  assert.throws(() => decodeCachedEmail(JSON.stringify(invalid)), /Invalid mail cache/);
});

test('Reply metadata survives cache refresh and malformed optional fields are rejected', () => {
  const source = { ...mail(), cc: [{name: '', email: 'copy@example.test'}], references: ['root@example.test'], inReplyTo: ['parent@example.test'] };
  const before = cacheEmail(source, true, null, 100);
  assert.deepEqual(cacheEmail({...source, references: []}, false, before, 200).mail.references, source.references);
  for (const field of ['cc', 'references', 'inReplyTo']) {
    assert.throws(() => decodeCachedEmail(JSON.stringify({...before, mail: {...source, [field]: {}}})), /Invalid mail cache/);
  }
});

test('Seven-day retention uses the download time and is not prolonged by inbox refreshes', () => {
  const { MAIL_RETENTION_MS, cacheIsFresh, retainedEmail } = require('../.tools/test-output/data/MailCacheModel.js');
  const before = cacheEmail({...mail(), attachments:[{id:'2',name:'report.pdf',contentType:'application/pdf',size:123,sizeIsEncoded:true}]}, true, null, 100);
  assert.equal(cacheIsFresh(100,100+MAIL_RETENTION_MS-1),true);
  assert.equal(cacheIsFresh(100,100+MAIL_RETENTION_MS),false);
  assert.equal(cacheIsFresh(101,100),false);
  const refresh=cacheEmail({...mail(),textBody:null},false,before,100+MAIL_RETENTION_MS-1);
  assert.equal(refresh.bodySavedAt,100);
  assert.equal(refresh.mail.attachments[0].name,'report.pdf');
  const expired=retainedEmail(refresh,100+MAIL_RETENTION_MS);
  assert.equal(expired.bodySavedAt,null);assert.equal(expired.mail.textBody,null);assert.equal(expired.mail.htmlBody,null);
  assert.equal(expired.mail.attachments,undefined);
  assert.equal(expired.mail.subject,'Cached');
});

test('Cached mail from before attachment support is refreshed once; partial bodies can retry', () => {
  const { cacheReadyForReading } = require('../.tools/test-output/data/MailCacheModel.js');
  const old=cacheEmail({...mail(),hasAttachment:true},true,null,100);
  assert.equal(cacheReadyForReading(old,200),false);
  const current={...old,mail:{...old.mail,attachments:[{id:'2',name:'report.pdf',contentType:'application/pdf',size:123,sizeIsEncoded:true}]}};
  assert.equal(cacheReadyForReading(current,200),true);
  assert.equal(cacheReadyForReading({...current,mail:{...current.mail,bodyEncodingProblem:true}},200),false);
  assert.equal(cacheReadyForReading({...current,mail:{...current.mail,bodyTruncated:true}},200),false);
});

test('Unknown folder counts survive cache reload without turning into a known zero', () => {
  const box = { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
    totalEmails: 0, unreadEmails: 0, countsKnown: false,
    maySetSeen: false, maySetKeywords: false, mayAddItems: false, mayRemoveItems: false };
  const record = {version:1, savedAt:100, boxes:[box]};
  assert.equal(decodeCachedBoxes(JSON.stringify(record)).boxes[0].countsKnown, false);
  const old = {...box}; delete old.countsKnown;
  assert.equal(decodeCachedBoxes(JSON.stringify({...record, boxes:[old]})).boxes[0].countsKnown, undefined);
  assert.throws(() => decodeCachedBoxes(JSON.stringify({...record, boxes:[{...box, countsKnown:'false'}]})));
});

test('Older decoded bodies refresh once while remaining available offline', () => {
  const { BODY_DECODER_REVISION, cacheReadyForReading } = require('../.tools/test-output/data/MailCacheModel.js');
  const old = cacheEmail(mail(), true, null, 100);
  delete old.bodyDecoderRevision;
  const loaded = decodeCachedEmail(JSON.stringify(old));
  assert.equal(loaded.mail.textBody, 'Body 鸿蒙 📬');
  assert.equal(cacheReadyForReading(loaded, 200), false);
  const summary = cacheEmail({ ...mail(), textBody: null, subject: 'Corrected subject' }, false, loaded, 200);
  assert.equal(summary.mail.textBody, loaded.mail.textBody);
  assert.equal(summary.mail.subject, 'Corrected subject');
  assert.equal(summary.bodySavedAt, 100);
  assert.equal(cacheReadyForReading(summary, 300), false);
  const refreshed = cacheEmail(mail(), true, summary, 300);
  assert.equal(refreshed.bodyDecoderRevision, BODY_DECODER_REVISION);
  assert.equal(cacheReadyForReading(decodeCachedEmail(JSON.stringify(refreshed)), 400), true);
  assert.equal(cacheReadyForReading(cacheEmail({ ...mail(), textBody: null }, false, refreshed, 500), 600), true);
  assert.equal(cacheReadyForReading({ ...refreshed, bodyDecoderRevision: BODY_DECODER_REVISION + 1 }, 400), false);
  for (const revision of ['1', -1, 1.5]) {
    assert.throws(() => decodeCachedEmail(JSON.stringify({ ...refreshed, bodyDecoderRevision: revision })), /Invalid mail cache/);
  }
});

test('A failed body decode retains the same message preview and a usable body replaces it', () => {
  const before = cacheEmail({ ...mail(), preview: 'Saved summary', textBody: null }, false, null, 100);
  const undecodable = { ...mail(), preview: '', textBody: null, htmlBody: null, bodyEncodingProblem: true };
  const failed = cacheEmail(undecodable, true, before, 200);
  assert.equal(failed.mail.preview, 'Saved summary');
  assert.equal(failed.mail.bodyEncodingProblem, true);
  assert.equal(cacheEmail({ ...undecodable, id: 'different-message' }, true, before, 200).mail.preview, '');
  const recovered = cacheEmail({ ...mail(), preview: '', textBody: 'Recovered body 中文' }, true, failed, 300);
  assert.equal(recovered.mail.preview, 'Recovered body 中文');
});

test('Cached Inbox creation hints round-trip without a fake mailbox and reject malformed destinations', () => {
  const inbox = { id: 'inbox', name: 'Inbox', parentId: null, role: 'inbox', sortOrder: 0,
    totalEmails: 4, unreadEmails: 2, maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true,
    archiveDestinationId: 'archive', archiveDestinationName: 'INBOX.Archive' };
  const encoded = box => JSON.stringify({ version: 1, savedAt: 100, roleRevision: 4, boxes: [box] });
  assert.deepEqual(decodeCachedBoxes(encoded(inbox)).boxes, [inbox]);
  for (const change of [{ archiveDestinationId: 'inbox' }, { archiveDestinationId: '../archive' },
    { archiveDestinationName: null }, { archiveDestinationName: 'Archive\r\n' }, { archiveDestinationId: undefined },
    { role: 'sent' }]) assert.throws(() => decodeCachedBoxes(encoded({ ...inbox, ...change })), /Invalid mail cache/);
  const legacy = { ...inbox }; delete legacy.archiveDestinationId; delete legacy.archiveDestinationName;
  assert.deepEqual(decodeCachedBoxes(encoded(legacy)).boxes, [legacy]);
});
