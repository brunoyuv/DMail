// Strict synthetic IDLE scenarios. A separate metadata checkpoint triggers the
// push deterministically, so readiness and arrival cannot collapse in slow CI.
exports.modes = ['idle-watch', 'idle-unsupported', 'idle-trigger', 'idle-cancel'];
const idling = new Map();
exports.done = function(socket, session) {
  const tag = idling.get(socket);
  if (!tag) return false;
  idling.delete(socket); session.idleDone = (session.idleDone || 0) + 1;
  socket.write(`${tag} OK IDLE finished\r\n`); return true;
};
exports.handle = function(socket, session, method, args, tag) {
  if (!exports.modes.includes(session.mode)) return false;
  function fail(reason) { session.violation = reason; socket.destroy(); }
  if (method === 'EXAMINE') {
    if (!/^(?:INBOX|"INBOX")$/i.test(args) || session.idleExaminations) { fail('IDLE must examine INBOX once'); return true; }
    session.idleExaminations = 1;
    if (session.mode === 'idle-cancel') return true; // cancellation must close this pending command
    socket.write('* FLAGS (\\Seen)\r\n* 80 EXISTS\r\n* OK [UIDVALIDITY 77] Valid\r\n* OK [UIDNEXT 181] Next\r\n' + `${tag} OK [READ-ONLY] examined\r\n`);
    if (session.mode === 'idle-trigger') {
      for (const [connection] of idling) {
        if (!connection.destroyed) { connection.write('* 81 EXISTS\r\n'); session.pushes = (session.pushes || 0) + 1; }
      }
    }
  } else if (method === 'IDLE') {
    if (session.mode !== 'idle-watch' || !session.idleExaminations || args !== '' || session.idleStarts) {
      fail('IDLE requires the same selected connection and is started once'); return true;
    }
    session.idleStarts = 1; idling.set(socket, tag);
    socket.on('close', () => idling.delete(socket));
    socket.write('+ idling\r\n');
  } else if (method === 'LOGOUT' && session.mode === 'idle-trigger') {
    socket.end(`* BYE Logging out\r\n${tag} OK completed\r\n`);
  } else { fail('Unexpected command in IDLE fixture'); }
  return true;
};
