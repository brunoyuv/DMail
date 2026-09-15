const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const moduleValue = { exports: {} };
new Function('module', 'exports', ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/smtp/OutgoingAttachments.ts', 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText)(moduleValue, moduleValue.exports);
const { outgoingAttachmentsValid, outgoingAttachmentInput, OUTGOING_ATTACHMENT_BYTES } = moduleValue.exports;
const attachment = { id: '167c7953-fbc4-412a-ab77-3e9cc0e87b2a', name: '中文 📎.pdf', contentType: 'application/pdf', size: 3, file: 'opaque-owned-ref' };

test('Old drafts and metadata-only validation do not read or serialize attachment bytes', () => {
  assert.equal(outgoingAttachmentsValid(undefined), true);
  assert.deepEqual(outgoingAttachmentInput(undefined, undefined, false), []);
  const values = outgoingAttachmentInput([attachment], undefined, true);
  assert.deepEqual(values, [{ id: attachment.id, name: attachment.name, contentType: attachment.contentType, size: 3 }]);
  assert.ok(!JSON.stringify(values).includes(attachment.file));
});

test('Attachment metadata rejects header injection, broken Unicode, duplicates, byte payloads and bounded totals', () => {
  assert.equal(outgoingAttachmentsValid([attachment]), true);
  for (const change of [{ name: 'bad\r\nBcc: injected' }, { name: '\ud800' }, { name: '界'.repeat(171) },
    { contentType: 'multipart/mixed' }, { contentType: 'application/pdf; charset=bad' }, { size: -1 }, { size: 1.5 },
    { id: 'not-an-id' }, { base64: 'AQID' }, { file: '' }]) {
    assert.equal(outgoingAttachmentsValid([{ ...attachment, ...change }]), false, JSON.stringify(change));
  }
  assert.equal(outgoingAttachmentsValid([attachment, { ...attachment, id: attachment.id.toUpperCase() }]), false);
  assert.equal(outgoingAttachmentsValid([{ ...attachment, size: OUTGOING_ATTACHMENT_BYTES }]), true);
  assert.equal(outgoingAttachmentsValid([{ ...attachment, size: OUTGOING_ATTACHMENT_BYTES + 1 }]), false);
  assert.equal(outgoingAttachmentsValid(Array.from({ length: 11 }, (_, index) => ({ ...attachment, id: `00000000-0000-0000-0000-${String(index).padStart(12, '0')}`, size: 0 }))), false);
});

test('Ephemeral submission requires the exact ordered metadata and bounded matching bytes', () => {
  const data = { id: attachment.id, name: attachment.name, contentType: attachment.contentType, size: 3, base64: 'AQID' };
  assert.deepEqual(outgoingAttachmentInput([attachment], [data], false), [data]);
  for (const bytes of [undefined, [], [{ ...data, id: 'different' }], [{ ...data, name: 'different' }],
    [{ ...data, contentType: 'text/plain' }], [{ ...data, size: 2 }], [{ ...data, base64: 'AQI=' + 'AAAA' }],
    [{ ...data, base64: 'A!ID' }]]) {
    assert.throws(() => outgoingAttachmentInput([attachment], bytes, false));
  }
  const empty = { ...attachment, size: 0 };
  assert.equal(outgoingAttachmentInput([empty], [{ ...data, size: 0, base64: '' }], false)[0].base64, '');
});
