// Strict local polling scenarios: only EXAMINE, optional STATUS and UID/FLAGS FETCH.
const assert = require('node:assert/strict');
exports.modes = ['poll-basic', 'poll-no-next', 'poll-epoch', 'poll-empty',
  'poll-count-rejected', 'poll-count-missing', 'poll-count-invalid', 'poll-count-drop', 'poll-count-stall'];
exports.handle = function inboxCheckFixture(socket, session, method, args, tag) {
  if (!exports.modes.includes(session.mode)) return false;
  const after = (session.pollFetches || 0) > 0;
  const count = session.mode === 'poll-empty' ? 0 : after ? 81 : 80;
  const next = after ? 182 : 181;
  const validity = after && session.mode === 'poll-epoch' ? 78 : 77;
  try {
    if (method === 'EXAMINE') {
      assert.match(args, /^(?:INBOX|"INBOX")$/);
      session.pollExaminations = (session.pollExaminations || 0) + 1;
      socket.write(`* FLAGS (\\Seen \\Flagged)\r\n* ${count} EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY ${validity}] Valid\r\n`);
      if (session.mode !== 'poll-no-next') socket.write(`* OK [UIDNEXT ${next}] Next\r\n`);
      socket.write(`${tag} OK [READ-ONLY] Selected\r\n`);
    } else if (method === 'STATUS') {
      if (/ \(MESSAGES UNSEEN\)$/.test(args)) {
        assert.match(args, /^(?:INBOX|"INBOX") \(MESSAGES UNSEEN\)$/);
        assert.equal(session.pollCountStatuses || 0, 0, 'count metadata is queried at most once');
        assert.equal(session.pollExaminations, after ? 2 : 1);
        session.pollCountStatuses = 1;
        if (session.mode === 'poll-count-rejected') socket.write(`${tag} NO Optional count unavailable\r\n`);
        else if (session.mode === 'poll-count-drop') socket.destroy();
        else if (session.mode === 'poll-count-stall') { /* No reply: native count deadline must close this connection. */ }
        else {
          const unread = session.mode === 'poll-empty' ? 0 : session.mode === 'poll-count-invalid' ? count + 1 : after ? 62 : 61;
          const unseen = session.mode === 'poll-count-missing' ? '' : ` UNSEEN ${unread}`;
          socket.write(`* STATUS "INBOX" (MESSAGES ${count}${unseen})\r\n${tag} OK Completed\r\n`);
        }
      } else {
        assert.equal(session.mode, 'poll-no-next');
        assert.equal(after, false, 'post-FETCH identity verification must not require UIDNEXT');
        assert.match(args, /^(?:INBOX|"INBOX") \(MESSAGES UIDVALIDITY UIDNEXT\)$/);
        session.pollStatuses = (session.pollStatuses || 0) + 1;
        socket.write(`* STATUS "INBOX" (MESSAGES ${count} UIDVALIDITY ${validity} UIDNEXT ${next})\r\n${tag} OK Completed\r\n`);
      }
    } else if (method === 'FETCH') {
      assert.equal(session.pollExaminations, 1);
      assert.equal(after, false);
      assert.equal(args, '31:80 (UID FLAGS)');
      session.pollFetches = 1;
      for (let sequence = 31; sequence <= 80; sequence++) {
        const uid = sequence + 100;
        const flags = uid === 176 ? '' : ` FLAGS (${uid % 2 ? '\\Seen' : ''})`;
        socket.write(`* ${sequence} FETCH (UID ${uid}${flags})\r\n`);
      }
      // Both an unrelated sequence update and a later arrival are excluded.
      socket.write(`* 1 FETCH (UID 170 FLAGS (\\Seen))\r\n* 81 FETCH (UID 181 FLAGS ())\r\n${tag} OK Completed\r\n`);
    } else if (method === 'LOGOUT') {
      socket.end(`* BYE Logging out\r\n${tag} OK Completed\r\n`);
    } else {
      throw new Error('Polling attempted a non-metadata or mutating command');
    }
  } catch (error) { session.violation = String(error); socket.destroy(); }
  return true;
};
