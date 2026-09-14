// Isolated IMAP Sent-copy fixture. It accepts only synthetic credentials and
// never retrieves messages, forwards mail, or contacts another server.
const tls = require('node:tls');
const assert = require('node:assert/strict');
module.exports = function sentFixture(options, stats, sockets) {
  stats.sentCopies = [];
  const server = tls.createServer(options, socket => {
    const record = { mode: '', messages: [], appendAttempts: 0, statusCalls: 0, closed: false };
    stats.sentCopies.push(record); sockets.add(socket);
    let buffer = Buffer.alloc(0), literal = null;
    const write = line => socket.write(line + '\r\n');
    socket.on('close', () => { record.closed = true; sockets.delete(socket); });
    socket.on('error', () => {});
    socket.on('data', bytes => {
      buffer = Buffer.concat([buffer, bytes]);
      try {
        while (buffer.length) {
          if (literal) {
            if (buffer.length < literal.length + 2) return;
            const text = buffer.subarray(0, literal.length).toString('utf8');
            assert.equal(buffer.subarray(literal.length, literal.length + 2).toString(), '\r\n');
            buffer = buffer.subarray(literal.length + 2);
            record.messages.push(text);
            const tag = literal.tag; literal = null;
            if (record.mode === 'sent-drop') { socket.destroy(); return; }
            if (record.mode === 'sent-reject') { write(`${tag} NO [OVERQUOTA] rejected`); continue; }
            write(`${tag} OK [APPENDUID 100 42] saved`); continue;
          }
          const end = buffer.indexOf('\r\n'); if (end < 0) return;
          const line = buffer.subarray(0, end).toString('utf8'); buffer = buffer.subarray(end + 2);
          const [tag, command] = line.split(' ');
          if (command === 'CAPABILITY') { write('* CAPABILITY IMAP4rev1 SPECIAL-USE'); write(`${tag} OK capability`); }
          else if (command === 'LOGIN') {
            const match = /^\S+ LOGIN "?(sent-(?:success|reject|drop|missing|ambiguous|conventional|nested|conventional-ambiguous))"? "?fixture-password"?$/.exec(line);
            assert.ok(match, 'non-synthetic Sent login'); record.mode = match[1]; write(`${tag} OK authenticated`);
          } else if (command === 'LIST') {
            assert.ok(record.mode, 'LIST before login');
            write('* LIST () "/" "INBOX"');
            if (record.mode === 'sent-conventional' || record.mode === 'sent-conventional-ambiguous') {
              write('* LIST () "/" "Sent Items"');
              if (record.mode === 'sent-conventional-ambiguous') write('* LIST () "/" "Sent"');
            } else if (record.mode === 'sent-nested') { write('* LIST () "." "INBOX.Sent"'); }
            else {
              if (record.mode !== 'sent-missing') write('* LIST (\\Sent) "/" "localized-sent-folder"');
              if (record.mode === 'sent-ambiguous') write('* LIST (\\Sent) "/" "second-sent-folder"');
            }
            write(`${tag} OK listed`);
          } else if (command === 'STATUS') {
            assert.ok(['sent-conventional', 'sent-nested'].includes(record.mode));
            const match = /^\S+ STATUS ("(?:INBOX|Sent Items|INBOX\.Sent)"|INBOX|INBOX\.Sent) \(MESSAGES UNSEEN\)$/.exec(line);
            assert.ok(match, 'unexpected Sent STATUS'); record.statusCalls++;
            write(`* STATUS ${match[1]} (MESSAGES 0 UNSEEN 0)`); write(`${tag} OK status`);
          } else if (command === 'APPEND') {
            assert.ok(['sent-success', 'sent-reject', 'sent-drop', 'sent-conventional', 'sent-nested'].includes(record.mode));
            const match = /^\S+ APPEND ("Sent Items"|"?INBOX\.Sent"?|"?localized-sent-folder"?) \(\\Seen\) \{(\d+)\}$/.exec(line);
            assert.ok(match, 'unexpected Sent APPEND'); record.appendAttempts++;
            assert.equal(match[1].replaceAll('"', ''), record.mode === 'sent-conventional' ? 'Sent Items' : record.mode === 'sent-nested' ? 'INBOX.Sent' : 'localized-sent-folder');
            const length = Number(match[2]); assert.ok(length > 0 && length < 2097152);
            literal = { length, tag }; write('+ ready');
          } else if (command === 'LOGOUT') { write('* BYE logout'); write(`${tag} OK logout`); socket.end(); }
          else { throw new Error('unexpected Sent command'); }
        }
      } catch (error) { stats.violations.push(String(error)); socket.destroy(); }
    });
    write('* OK Sent-copy fixture');
  });
  server.on('tlsClientError', () => {});
  return server.listen(9773, '127.0.0.1');
};
