// Synthetic preview metadata and bounded inline text samples only.
const assert = require('node:assert/strict');
exports.modes = ['preview-sample', 'preview-server', 'preview-stall', 'preview-partial', 'preview-utf8-boundary', 'preview-malformed'];
const plain = 'A plain summary 中文 café 😀';
const html = '<p>An HTML summary &amp; details</p>';
const samples = { 42: Buffer.from(plain).toString('base64'), 43: Buffer.from(html).toString('base64') };
function sample(mode, uid) {
  if (mode !== 'preview-utf8-boundary') return Buffer.from(samples[uid]);
  const prefix = Buffer.from('中文 café 😀 '), size = uid === 42 ? 2048 : 1536;
  const body = Buffer.concat([prefix, Buffer.alloc(size - prefix.length - 2, 97), Buffer.from([0xf0, 0x9f])]);
  return uid === 42 ? body : Buffer.from(body.toString('base64'));
}
exports.handle = function previewFixture(socket, session, method, args, tag) {
  if (!exports.modes.includes(session.mode)) return false;
  try {
    if (method === 'EXAMINE') {
      assert.match(args, /^(?:INBOX|"INBOX")$/);
      session.previewExamines = (session.previewExamines || 0) + 1;
      socket.write(`* 2 EXISTS\r\n* OK [UIDVALIDITY 77] Valid\r\n* OK [UIDNEXT 44] Next\r\n${tag} OK [READ-ONLY] Selected\r\n`);
    } else if (method === 'FETCH') {
      assert.match(args, /^1:2 \(/); assert.ok(args.includes('BODYSTRUCTURE'));
      assert.ok(!args.includes('BODY.PEEK['));
      if (session.mode === 'preview-server') assert.ok(args.includes('PREVIEW (LAZY)'));
      session.previewHeaders = (session.previewHeaders || 0) + 1;
      for (const uid of [42, 43]) {
        const subtype = uid === 42 || session.mode === 'preview-utf8-boundary' ? 'PLAIN' : 'HTML';
        const encoding = session.mode === 'preview-utf8-boundary' && uid === 42 ? '8BIT' : 'BASE64';
        const leaf = `("TEXT" "${subtype}" ("CHARSET" "utf-8") NIL NIL "${encoding}" ${sample(session.mode, uid).length + 100} 1)`;
        // Both messages contain a large attachment. Only text part2 may be sampled.
        const structure = `(("APPLICATION" "PDF" NIL NIL NIL "BASE64" 4000000 NIL ("ATTACHMENT" ("FILENAME" "fixture.pdf"))) ${leaf} "MIXED")`;
        const envelope = `("Sun, 13 Sep 2026 10:00:00 +0000" "Synthetic preview ${uid}" (("Sender" NIL "sender" "example.test")) NIL NIL NIL NIL NIL NIL "<${uid}@example.test>")`;
        socket.write(`* ${uid - 41} FETCH (UID ${uid} FLAGS () ENVELOPE ${envelope} BODYSTRUCTURE ${structure}`);
        if (session.mode === 'preview-server') {
          const text = Buffer.from(`Server preview ${uid} 中文`);
          socket.write(` PREVIEW {${text.length}}\r\n`); socket.write(text);
        }
        socket.write(')\r\n');
      }
      socket.write(`${tag} OK Completed\r\n`);
    } else if (method === 'UID FETCH') {
      assert.equal(session.previewExamines, 2);
      assert.equal(session.mode === 'preview-server', false);
      assert.equal(args, '42:43 (UID BODY.PEEK[2]<0.2048>)');
      session.previewSamples = (session.previewSamples || 0) + 1;
      assert.equal(session.previewSamples, 1);
      if (session.mode === 'preview-stall') return true;
      for (const uid of [42, 43]) {
        if (session.mode === 'preview-partial' && uid === 42) continue;
        const bytes = session.mode === 'preview-malformed' && uid === 43 ? Buffer.alloc(2049, 65) : sample(session.mode, uid);
        socket.write(`* ${uid - 41} FETCH (UID ${uid} BODY[2]<0> {${bytes.length}}\r\n`);
        socket.write(bytes); socket.write(')\r\n');
        if (session.mode === 'preview-malformed' && uid === 42) {
          socket.write(`* 99 FETCH (UID ${uid} BODY[2]<0> {${bytes.length}}\r\n`);
          socket.write(bytes); socket.write(')\r\n');
        }
      }
      socket.write(`${tag} OK Completed\r\n`);
    } else if (method === 'LOGOUT') socket.end(`* BYE Closing\r\n${tag} OK Completed\r\n`);
    else throw new Error('Unexpected preview request');
  } catch (error) { session.violation = String(error); socket.destroy(); }
  return true;
};
