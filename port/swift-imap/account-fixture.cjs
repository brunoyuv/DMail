// Account and flag-mutation fixture scenarios for the production account/UI adapter.
const mailFlags = new Map();
let gesturePages = 0;
let listRetryFailures = 0;
// Three deliberately different wire encodings exercise the shipping IMAP/MIME
// decoder. IMAP literals retain folded RFC 2047 whitespace without putting CRLF
// inside an invalid quoted string. Bodies are served as selected MIME parts.
const encodingSender = '=?UTF-8?Q?=E5=B1=B1=E7=94=B0_=E5=A4=AA=E9=83=8E?=';
const encodingCases = [
  { uid: 201, subject: 'UTF-8 =?UTF-8?Q?=E4=B8=AD=E6=96=87?=', subtype: 'PLAIN', charset: 'UTF-8',
    transfer: 'QUOTED-PRINTABLE', data: '=E4=B8=\r\n=AD=E6=96=87' },
  { uid: 202, subject: 'Shift_JIS =?UTF-8?B?5pel5pys6Kqe?=', subtype: 'PLAIN', charset: 'Shift_JIS',
    transfer: 'QUOTED-PRINTABLE', data: '=93=FA=96{=8C=EA' },
  { uid: 203, subject: 'Re: =?UTF-8?B?5Lit5paH?=\r\n\t=?UTF-8?Q?_caf=C3=A9_=F0=9F=93=A8?= update', subtype: 'HTML', charset: 'US-ASCII',
    transfer: 'BASE64', data: Buffer.from('<p>中文 café 😀</p>').toString('base64') }
];
const emptyBodyCases = [
  { uid: 301, subject: 'Empty plain body', subtype: 'PLAIN', charset: 'UTF-8', transfer: '8BIT', data: '' },
  { uid: 302, subject: 'Empty HTML body', subtype: 'HTML', charset: 'UTF-8', transfer: '8BIT', data: '' },
  { uid: 303, subject: 'Attachment-only body', attachment: true, data: '' },
  { uid: 304, subject: 'Invalid UTF-8 body', subtype: 'PLAIN', charset: 'UTF-8', transfer: 'BASE64', data: '/w==' },
  { uid: 305, subject: 'Missing advertised text', subtype: 'PLAIN', charset: 'UTF-8', transfer: '8BIT', data: '', advertised: 40 },
  { uid: 306, subject: 'Tolerated transfer declaration', subtype: 'PLAIN', charset: 'UTF-8', transfer: 'BASE64', data: 'Y' }
];
const encodingFlags = new Map([...encodingCases, ...emptyBodyCases].map(item => [item.uid, new Set(['\\Seen'])]));
function encodingFixture(socket, session, method, args, tag) {
  const cases = session.mode === 'emptybody' ? emptyBodyCases : encodingCases;
  const next = cases.at(-1).uid + 1;
  const ok = () => socket.write(`${tag} OK Completed\r\n`);
  const reject = reason => { session.violation = reason; socket.destroy(); };
  if (method === 'LIST') {
    socket.write('* LIST (\\HasNoChildren) "/" "INBOX"\r\n'); ok();
  } else if (method === 'STATUS') {
    socket.write(`* STATUS "INBOX" (MESSAGES ${cases.length} UNSEEN 0 UIDVALIDITY 77 UIDNEXT ${next})\r\n`); ok();
  } else if (method === 'SELECT' || method === 'EXAMINE') {
    if (!/^(?:"INBOX"|INBOX)$/.test(args)) { reject('unexpected encoding mailbox'); return true; }
    session.selects = (session.selects || 0) + 1;
    session.readOnly = method === 'EXAMINE';
    socket.write(`* FLAGS (\\Seen \\Flagged)\r\n* ${cases.length} EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY 77] Valid\r\n* OK [UIDNEXT ${next}] Next\r\n* OK [PERMANENTFLAGS (\\Seen \\Flagged)] Flags\r\n`);
    socket.write(`${tag} OK [${session.readOnly ? 'READ-ONLY' : 'READ-WRITE'}] Selected\r\n`);
  } else if (method === 'FETCH' || method === 'UID FETCH') {
    const uidFetch = method === 'UID FETCH';
    const match = /^(\d+)(?::(\d+))? /.exec(args);
    const headerOnly = /BODY\.PEEK\[HEADER\.FIELDS \("?REFERENCES"?\)\]/i.test(args);
    const sections = [...args.matchAll(/BODY\.PEEK\[([0-9.]+(?:MIME)?)\]/g)].map(value => value[1]);
    if (!match || !session.selects || args.includes('BODY.PEEK[]') || args.includes('BODY[]') ||
      (args.includes('BODY.PEEK[') && !headerOnly && sections.length === 0)) {
      reject('unexpected encoding fetch'); return true;
    }
    const start = Number(match[1]), end = Number(match[2] || match[1]);
    const selected = uidFetch ? cases.filter(item => item.uid >= start && item.uid <= end) : cases.slice(start - 1, end);
    if (end < start || end - start >= cases.length || selected.length === 0 || (!uidFetch && (start < 1 || end > cases.length))) {
      reject('unbounded encoding fetch'); return true;
    }
    session.encodingFetches ??= [];
    session.encodingFetches.push({ uidFetch, start, end, headerOnly, sections });
    const literal = value => `{${Buffer.byteLength(value)}}\r\n${value}`;
    for (const item of selected) {
      const sequence = cases.indexOf(item) + 1;
      const envelope = `("Sun, 13 Sep 2026 10:00:00 +0000" ${literal(item.subject)} (("${encodingSender}" NIL "sender" "example.test")) NIL NIL (("Reader" NIL "reader" "example.test")) NIL NIL NIL "<encoding-${item.uid}@example.test>")`;
      socket.write(`* ${sequence} FETCH (UID ${item.uid} FLAGS (${[...encodingFlags.get(item.uid)].join(' ')}) INTERNALDATE "13-Sep-2026 10:00:00 +0000" ENVELOPE ${envelope}`);
      if (headerOnly) {
        const headers = 'References: <encoding-root@example.test>\r\n\r\n';
        socket.write(` BODY[HEADER.FIELDS (REFERENCES)] ${literal(headers)}`);
      }
      if (args.includes('BODYSTRUCTURE')) {
        if (item.attachment) socket.write(' BODYSTRUCTURE ("APPLICATION" "PDF" ("NAME" "report.pdf") NIL NIL "BASE64" 100 NIL ("ATTACHMENT" ("FILENAME" "report.pdf")) NIL NIL)');
        else socket.write(` BODYSTRUCTURE ("TEXT" "${item.subtype}" ("CHARSET" "${item.charset}") NIL NIL "${item.transfer}" ${item.advertised ?? Buffer.byteLength(item.data)} 1)`);
      }
      for (const [index, section] of sections.entries()) {
        if (!['1.MIME', '1'].includes(section)) { reject('unexpected encoding part'); return true; }
        // Valid servers can split attributes for one UID across FETCH records.
        // Keep the UTF-8 case on this path for both ordinary and pooled reads.
        if (item.uid === 201 && index > 0) {
          session.encodingSplitResponses = (session.encodingSplitResponses || 0) + 1;
          socket.write(`)\r\n* ${sequence} FETCH (UID ${item.uid}`);
        }
        const value = section === '1.MIME' ? `Content-Type: text/${item.subtype.toLowerCase()}; charset=${item.charset}\r\nContent-Transfer-Encoding: ${item.transfer}\r\n\r\n` : item.data;
        socket.write(` BODY[${section}] ${literal(value)}`);
      }
      socket.write(')\r\n');
      // An unrelated flag update must not invalidate the requested body UID.
      if (item.uid === 202) {
        session.encodingUnsolicitedUpdates = (session.encodingUnsolicitedUpdates || 0) + 1;
        socket.write('* 1 FETCH (UID 201 FLAGS (\\Seen))\r\n');
      }
    }
    ok();
  } else if (method === 'UID STORE') {
    const update = /^(20[1-3]) ([+-])FLAGS\.SILENT \((\\Seen|\\Flagged)\)$/.exec(args);
    if (!update || !session.selects || session.readOnly) { reject('unsafe encoding STORE'); return true; }
    const flags = encodingFlags.get(Number(update[1]));
    if (update[2] === '+') flags.add(update[3]); else flags.delete(update[3]);
    ok();
  } else if (method === 'LOGOUT') { socket.end(`* BYE Logging out\r\n${tag} OK Completed\r\n`); }
  else { reject('unexpected encoding command'); }
  return true;
}
module.exports = function handle(socket, session, method, args, tag, mime) {
  if (session.mode === 'encoding' || session.mode === 'emptybody') { return encodingFixture(socket, session, method, args, tag); }
  const modes = ['html', 'gesture', 'status-basic-only', 'status-fail', 'status-drop', 'list-retry', 'no-next', 'next-changed', 'next-missing', 'next-count', 'account', 'epoch', 'changed', 'missing', 'wronguid', 'writer', 'readonly', 'limited', 'noflags', 'wildcard', 'omitted', 'storefail', 'lost', 'ignored'];
  if (!modes.includes(session.mode)) return false;
  let readableParts = null, bodyStructure = null;
  if (session.mode === 'html') {
    const picture = 'iVBORw0KGgoAAAANSUhEUgAAAPAAAAAoCAIAAABPWuCHAAAAu0lEQVR4nO3SQQ2AMADAwIlABKJwyQddKJiLLekuqYPeuJ5XC/q/Wwsa208f0vbThwQ00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigUwENdCqggU4FNNCpgAY6FdBApwIa6FRAA50KaKBTAQ10KqCBTgU00KmABjoV0ECnAhroVEADnQpooFMBDXQqoIFOBTTQqYAGOhXQQKcCGuhUQAOdCmigU01KvnT6jr0z3wAAAABJRU5ErkJggg==';
    const html = '<h1>HTML mail works</h1><p>Rich text with <strong>bold</strong> and 日本語.</p><table style="background:#eaf2ff;padding:20px"><tr><td>Tablet reader</td><td>Two columns</td></tr></table><p>Embedded picture:</p><img src="cid:picture@example.test" width="80" height="80"><p>Remote picture:</p><img src="http://localhost:9770/picture.png" width="80" height="80"><div style="height:1200px">Long newsletter body</div><p>End of newsletter</p><script>document.body.innerHTML="SCRIPT EXECUTED";fetch("http://localhost:9770/script")</script><iframe src="http://localhost:9770/frame"></iframe><form action="http://localhost:9770/form"><input type="file"><button>Untrusted form</button></form>';
    readableParts = {
      '1.1': { headers: 'Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n', data: Buffer.from('Plain fallback 日本語').toString('base64') },
      '1.2': { headers: 'Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n', data: html },
      '2': { headers: 'Content-Type: image/png\r\nContent-ID: <picture@example.test>\r\nContent-Disposition: inline\r\nContent-Transfer-Encoding: base64\r\n\r\n', data: picture }
    };
    bodyStructure = `(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "BASE64" ${readableParts['1.1'].data.length} 1)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "8BIT" ${Buffer.byteLength(html)} 1) "ALTERNATIVE")`;
    bodyStructure = `(${bodyStructure}("IMAGE" "PNG" NIL "<picture@example.test>" NIL "BASE64" ${picture.length} NIL ("INLINE" NIL))("APPLICATION" "PDF" ("NAME" "report.pdf") NIL NIL "BASE64" 3327488 NIL ("ATTACHMENT" ("FILENAME" "report.pdf"))) "MIXED")`;
    mime = Buffer.from('From: Sender 日本語 <sender@example.test>\r\nTo: reader@example.test\r\nReferences: <root@example.test> (ignored <comment@example.test>)\r\n <older@example.test>\r\nSubject: HTML mail works\r\nMIME-Version: 1.0\r\nContent-Type: multipart/related;\r\n boundary="related"\r\n\r\n--related\r\nContent-Type: multipart/alternative;\r\n boundary="htmltest"\r\n\r\n--htmltest\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n' + Buffer.from('Plain fallback 日本語').toString('base64') + '\r\n--htmltest\r\nContent-Type:text/html;\r\n charset=utf-8\r\nContent-Transfer-Encoding:8bit\r\n\r\n' + html + '\r\n--htmltest--\r\n--related\r\nContent-Type: image/png\r\nContent-ID: <picture@example.test>\r\nContent-Disposition: inline\r\nContent-Transfer-Encoding: base64\r\n\r\n' + picture + '\r\n--related--\r\n');
  }
  const flagsFor = uid => {
    const key = `${session.mode}:${uid}`;
    if (!mailFlags.has(key)) mailFlags.set(key, new Set(['\\Answered', 'CustomLabel']));
    return mailFlags.get(key);
  };
  const ok = () => socket.write(`${tag} OK Completed\r\n`);
  const validity = session.mode === 'epoch' || (session.mode === 'changed' && session.selects > 1) ? 78 : 77;
  if (method === 'LIST') {
    session.listArguments = args;
    if (session.mode === 'list-retry' && listRetryFailures++ === 0) { socket.write(`${tag} NO Temporary listing failure\r\n`); return true; }
    socket.write('* LIST (\\HasNoChildren) "/" "INBOX"\r\n* LIST (\\HasNoChildren) "/" "Archive"\r\n'); ok();
  } else if (method === 'STATUS') {
    const mailbox = /^(?:"INBOX"|INBOX) /.test(args) ? 'INBOX' : 'Archive';
    session.statusArguments ??= []; session.statusArguments.push(args);
    if (session.mode === 'status-drop') { socket.destroy(); return true; }
    if (session.mode === 'status-fail') { socket.write(`${tag} NO Status temporarily unavailable\r\n`); return true; }
    if (session.mode === 'status-basic-only' && !/\(MESSAGES UNSEEN\)$/.test(args)) {
      socket.write(`${tag} BAD Unsupported status attributes\r\n`); return true;
    }
    const fallback = args.includes('UIDNEXT') && args.includes('UIDVALIDITY');
    const statusEpoch = session.mode === 'next-changed' && fallback ? 78 : 77;
    const statusCount = session.mode === 'next-count' && fallback ? 52 : 51;
    const statusNext = session.mode === 'next-missing' ? '' : ' UIDNEXT 93';
    socket.write(`* STATUS "${mailbox}" (MESSAGES ${mailbox === 'INBOX' ? statusCount : 0} RECENT 0 UNSEEN ${mailbox === 'INBOX' ? Array.from({ length: 51 }, (_, i) => i + 42).filter(uid => !flagsFor(uid).has('\\Seen')).length : 0}${statusNext} UIDVALIDITY ${statusEpoch})\r\n`); ok();
  } else if (method === 'EXAMINE' || method === 'SELECT') {
    session.selects = (session.selects || 0) + 1;
    const epoch = session.mode === 'epoch' || (session.mode === 'changed' && session.selects > 1) ? 78 : 77;
    session.readOnly = method === 'EXAMINE' || session.mode === 'readonly';
    const permanent = session.mode === 'limited' ? '\\Seen' : session.mode === 'noflags' ? '' : session.mode === 'wildcard' ? '\\*' : '\\Seen \\Flagged';
    if (method === 'SELECT' && session.mode !== 'omitted') socket.write(`* OK [PERMANENTFLAGS (${permanent})] Permissions\r\n`);
    const nextResponse = ['no-next', 'next-changed', 'next-missing', 'next-count'].includes(session.mode) ? '' : '* OK [UIDNEXT 93] Next\r\n';
    socket.write(`* FLAGS (\\Seen \\Flagged)\r\n* 51 EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY ${epoch}] Valid\r\n${nextResponse}${tag} OK [${session.readOnly ? 'READ-ONLY' : 'READ-WRITE'}] Selected\r\n`);
  } else if (method === 'UID STORE') {
    const update = /^(\d+) ([+-])FLAGS\.SILENT \((\\Seen|\\Flagged)\)$/.exec(args);
    if (!update || !session.selects || session.readOnly) {
      session.violation = 'unsafe STORE'; socket.destroy(); return true;
    }
    const uid = Number(update[1]), flag = update[3], enabled = update[2] === '+';
    session.stores ??= [];
    const flags = flagsFor(uid);
    const observed = { uid, flag, enabled, before: [...flags], after: [] };
    session.stores.push(observed);
    if (session.mode === 'storefail') { observed.after = [...flags]; socket.write(`${tag} NO [NOPERM] Rejected\r\n`); return true; }
    if (session.mode !== 'ignored') { if (enabled) flags.add(flag); else flags.delete(flag); }
    observed.after = [...flags];
    if (session.mode === 'lost') { socket.destroy(); return true; }
    // An untagged OK must never be mistaken for the STORE acknowledgement.
    socket.write('* OK Still processing\r\n');
    ok();
  } else if (method === 'FETCH' || method === 'UID FETCH') {
    const uidFetch = method === 'UID FETCH';
    const full = uidFetch && args.includes('BODY.PEEK[]');
    const headerOnly = /BODY\.PEEK\[HEADER\.FIELDS \("?REFERENCES"?\)\]/i.test(args);
    const sections = [...args.matchAll(/BODY\.PEEK\[([0-9.]+(?:MIME)?)\]/g)].map(match => match[1]);
    const match = uidFetch ? /^(\d+)(?::\1)? /.exec(args) : /^(\d+)(?::(\d+))? /.exec(args);
    if (!match || !session.selects || (args.includes('BODY') && !args.includes('BODYSTRUCTURE') && !full && !headerOnly && sections.length === 0)) {
      session.violation = 'unsafe account fetch'; session.rejectedFetch = args; socket.destroy(); return true;
    }
    const start = Number(match[1]), end = uidFetch ? start : Number(match[2] || match[1]);
    if (!uidFetch && (end-start > 49 || start < 1 || end > 51)) {
      session.violation = 'unbounded page'; socket.destroy(); return true;
    }
    session.accountFetches ??= []; session.accountFetches.push({ full, uidFetch, start, end, headerOnly, sections });
    if (uidFetch && session.mode === 'missing') { ok(); return true; }
    if (session.mode === 'gesture' && !uidFetch) { gesturePages++; session.gesturePage = gesturePages; }
    for (let value = start; value <= end; value++) {
      const uid = uidFetch ? (session.mode === 'wronguid' ? value+1 : value) : value+41;
      const sequence = uid-41;
      const reply = session.mode === 'html' ? '(("Support" NIL "support" "example.test"))' : 'NIL';
      const to = session.mode === 'html' ? '(("Reader" NIL "reader" "example.test") ("Me" NIL "sender" "example.test"))' : '(("Reader" NIL "reader" "example.test"))';
      const cc = session.mode === 'html' ? '(("Copy" NIL "copy" "example.test"))' : 'NIL';
      const envelope = `("Sun, 13 Sep 2026 10:00:00 +0000" "Message ${uid}${session.mode === 'gesture' ? ` refresh ${gesturePages}` : ''}" (("Sender" NIL "sender" "example.test")) NIL ${reply} ${to} ${cc} NIL NIL "<${uid}@example.test>")`;
      socket.write(`* ${sequence} FETCH (UID ${uid} FLAGS (${[...flagsFor(uid)].join(' ')}) INTERNALDATE "13-Sep-2026 10:00:00 +0000" ENVELOPE ${envelope}`);
      if (headerOnly) {
        const headers = Buffer.from('References: <root@example.test>\r\n <older@example.test>\r\n\r\n');
        socket.write(` BODY[HEADER.FIELDS (REFERENCES)] {${headers.length}}\r\n`); socket.write(headers);
        if (bodyStructure) socket.write(` BODYSTRUCTURE ${bodyStructure}`);
      }
      for (const section of sections) {
        const isMime = section.endsWith('.MIME');
        const part = readableParts?.[isMime ? section.slice(0,-5) : section];
        if (!part) { session.violation = 'downloaded attachment or unknown section'; socket.destroy(); return true; }
        const bytes = Buffer.from(isMime ? part.headers : part.data);
        socket.write(` BODY[${section}] {${bytes.length}}\r\n`); socket.write(bytes);
      }
      if (full) { socket.write(` BODY[] {${mime.length}}\r\n`); socket.write(mime); }
      socket.write(')\r\n');
    }
    ok();
  } else if (method === 'LOGOUT') {
    socket.end(`* BYE Logging out\r\n${tag} OK Completed\r\n`);
  } else { session.violation = 'unexpected account command'; socket.destroy(); }
  return true;
};
