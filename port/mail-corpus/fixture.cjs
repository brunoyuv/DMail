// Public RFC822 messages pass through the shipping Swift IMAP/MIME reader.
// Keep downloaded bytes intact; only normalize transport line endings to CRLF.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const manifest = require('./manifest.json');
const expectations = {
  'japanese.txt': '日本語', 'simple-multipart.anonymized.eml': 'xxxx xx xxx xxxxxxx xxxxx',
  'simple-embedded-message.anonymized.eml': 'xxxx xx xxx xxxxxxx xxxxx',
  'multipart-related-mhtml.txt': 'def', 'rfc2060.txt': 'This part specifier should be: 1',
  'empty-multipart.txt': 'This part should be on the same level',
  'delivery-status.anonymized.eml': '', 'missing-subtype.txt': ''
};
const cases = Object.entries(manifest.files).map(([name, entry], i) => {
  const raw = fs.readFileSync(path.join(root, '.tools/mail-corpus/mimekit', name));
  if (crypto.createHash('sha256').update(raw).digest('hex') !== entry.sha256) throw Error('Corpus checksum mismatch: '+name);
  return { uid: 100+i, name, expected: name.startsWith('body.') ? 'body' : expectations[name],
    bytes: Buffer.from(raw.toString('binary').replace(/\r?\n/g, '\r\n'), 'binary'), flags: new Set() };
});
const png = 'iVBORw0KGgoAAAANSUhEUgAAAPAAAAAoCAIAAABPWuCHAAAAu0lEQVR4nO3SQQ2AMADAwIlABKJwyQddKJiLLekuqYPeuJ5XC/q/Wwsa208f0vbThwQ00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigU01KvnT6jr0z3wAAAABJRU5ErkJggg==';
const detail = '<blockquote>A quoted reply should remain indented and readable. 日本語 中文.</blockquote>'+
  '<pre>Reference: ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789</pre>'+
  '<p>https://example.test/a/very/long/unbroken/newsletter/reference/ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789</p>'+
  '<table width="220" style="width:220px;border-collapse:collapse"><tr><td width="60" style="padding:6px;background:#e7f0fa">Team</td><td width="160" style="padding:6px">Small signature</td></tr><tr><td style="padding:6px">Name</td><td style="padding:6px">Avery Chen</td></tr></table>';
const wide = '<html><head><meta name="viewport" content="width=980"><style>.newsletter{width:900px;min-width:900px}.banner{background:#145cb3;color:white;padding:24px}</style></head><body><table class="newsletter" width="900" style="width:900px;min-width:900px"><tr><td colspan="2" class="banner"><h1>Wide newsletter</h1><p>HTML layout and picture test</p></td></tr><tr><td width="450">LEFT EDGE</td><td width="450" align="right">RIGHT EDGE</td></tr><tr><td colspan="2"><p>A readable newsletter must wrap inside the message pane. 日本語 中文.</p><img alt="Embedded test image" src="cid:visible@example.test" width="600" style="background:#14a183;height:80px"><p>'+('A long paragraph should wrap without clipping either edge. '.repeat(12))+'</p>'+detail+'<p>NEWSLETTER END</p></td></tr></table></body></html>';
cases.push({uid:117,name:'wide-newsletter.eml',expected:'Wide newsletter',flags:new Set(),bytes:Buffer.from('MIME-Version: 1.0\r\nContent-Type: multipart/related; boundary="wide"\r\n\r\n--wide\r\nContent-Type: text/html; charset=utf-8\r\n\r\n'+wide+'\r\n--wide\r\nContent-Type: image/png\r\nContent-ID: <visible@example.test>\r\nContent-Transfer-Encoding: base64\r\n\r\n'+png+'\r\n--wide--\r\n')});
const pdf = require('./large-pdf.cjs')();
const pdfBody = '<h1>PDF attachment message</h1><p>This body remains readable beside a 2.38 MiB PDF attachment.</p>';
const pdfEncoded = pdf.toString('base64').match(/.{1,76}/g).join('\r\n');
cases.push({uid:118,name:'large-pdf.eml',expected:'PDF attachment message',flags:new Set(),
  bytes:Buffer.from(`MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary="pdf"\r\n\r\n--pdf\r\nContent-Type: text/html; charset=utf-8\r\n\r\n${pdfBody}\r\n--pdf\r\nContent-Type: application/pdf; name="report.pdf"\r\nContent-Disposition: attachment; filename="report.pdf"\r\nContent-Transfer-Encoding: base64\r\n\r\n${pdfEncoded}\r\n--pdf--\r\n`),
  structure:`(("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "8BIT" ${pdfBody.length} 1)("APPLICATION" "PDF" ("NAME" "report.pdf") NIL NIL "BASE64" ${pdfEncoded.length} NIL ("ATTACHMENT" ("FILENAME" "report.pdf"))) "MIXED")`,
  body:pdfBody, attachmentBody:pdfEncoded});
// Small inboxes keep each real UI run bounded on compact screens. Across the
// three batches every public and generated message is still displayed.
const allCases = cases.slice();
function selectBatch(batch) {
  if (!Number.isInteger(batch) || batch < 0 || batch > 2) throw Error('Invalid corpus batch');
  const selected = allCases.slice().reverse().slice(batch * 7, batch * 7 + 7);
  cases.splice(0, cases.length, ...selected.reverse());
}
function handle(socket,session,method,args,tag) {
  if (session.mode !== 'corpus') return false;
  const ok=()=>socket.write(`${tag} OK Completed\r\n`);
  if(method==='LIST') { socket.write('* LIST (\\HasNoChildren) "/" "INBOX"\r\n');ok(); }
  else if(method==='STATUS') {socket.write(`* STATUS "INBOX" (MESSAGES ${cases.length} UNSEEN ${cases.filter(c=>!c.flags.has('\\Seen')).length} RECENT 0 UIDVALIDITY 77 UIDNEXT 119)\r\n`);ok();}
  else if(method==='SELECT'||method==='EXAMINE') {
    session.selected=true;
    socket.write(`* FLAGS (\\Seen \\Flagged)\r\n* ${cases.length} EXISTS\r\n* OK [UIDVALIDITY 77] Valid\r\n* OK [UIDNEXT 119] Next\r\n* OK [PERMANENTFLAGS (\\Seen \\Flagged)] Flags\r\n${tag} OK [${method==='SELECT'?'READ-WRITE':'READ-ONLY'}] Selected\r\n`);
  } else if(method==='UID STORE') {
    const match=/^(\d+) ([+-])FLAGS\.SILENT \((\\Seen|\\Flagged)\)$/.exec(args);
    const item=match&&cases.find(c=>c.uid===Number(match[1]));
    if(!session.selected||!item) throw Error('Invalid corpus flag mutation');
    if(match[2]==='+') item.flags.add(match[3]);else item.flags.delete(match[3]);ok();
  } else if(method==='FETCH'||method==='UID FETCH') {
    const match=/^(\d+)(?::(\d+))? /.exec(args);
    if(!session.selected||!match) throw Error('Invalid corpus fetch');
    const start=Number(match[1]),end=Number(match[2]||match[1]);
    const full=args.includes('BODY.PEEK[]');
    session.corpusFetches??=[];session.corpusFetches.push({start,end,full});
    const selected=method==='UID FETCH'?cases.filter(c=>c.uid>=start&&c.uid<=end):cases.slice(start-1,end);
    for(const item of selected) {
      const envelope=`("Sun, 13 Sep 2026 10:00:00 +0000" "${item.name}" (("Public corpus" NIL "fixture" "example.test")) NIL NIL (("Reader" NIL "reader" "example.test")) NIL NIL NIL "<${item.uid}@example.test>")`;
      socket.write(`* ${cases.indexOf(item)+1} FETCH (UID ${item.uid} FLAGS (${[...item.flags].join(' ')}) INTERNALDATE "13-Sep-2026 10:00:00 +0000" ENVELOPE ${envelope}`);
      if(item.structure && args.includes('BODYSTRUCTURE')) socket.write(` BODYSTRUCTURE ${item.structure}`);
      if(item.structure) {
        if(full) throw Error('Downloaded whole PDF message instead of a selected part');
        for(const [,section] of args.matchAll(/BODY\.PEEK\[([0-9.]+(?:MIME)?)\]/g)) {
          if(!['1.MIME','1','2.MIME','2'].includes(section))throw Error('Unexpected PDF section');
          if(section==='2') session.attachmentDownloads=(session.attachmentDownloads||0)+1;
          const data=Buffer.from(section==='2.MIME'?'Content-Type: application/pdf; name="report.pdf"\r\nContent-Disposition: attachment; filename="report.pdf"\r\nContent-Transfer-Encoding: base64\r\n\r\n':section==='2'?item.attachmentBody:section==='1.MIME'?'Content-Type: text/html; charset=utf-8\r\n\r\n':item.body);
          socket.write(` BODY[${section}] {${data.length}}\r\n`);socket.write(data);
        }
      }
      if(full) {socket.write(` BODY[] {${item.bytes.length}}\r\n`);socket.write(item.bytes);}
      socket.write(')\r\n');
    }ok();
  } else if(method==='LOGOUT') socket.end(`* BYE Bye\r\n${tag} OK Completed\r\n`);
  else throw Error('Unexpected corpus command');
  return true;
}
module.exports={handle,selectBatch,pdf:{bytes:pdf.length,sha256:crypto.createHash('sha256').update(pdf).digest('hex')},get index(){return cases.map(({uid,name,expected})=>({uid,name,expected}));}};
