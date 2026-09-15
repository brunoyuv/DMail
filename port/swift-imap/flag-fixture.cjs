// Loopback-only flag compatibility scenarios. No bodies, accounts or delivery.
const assert = require('node:assert/strict');
const modes = ['flag-no-next', 'flag-no-next-after', 'flag-unsolicited', 'flag-compat',
  'flag-missing-flags', 'flag-missing-target', 'flag-duplicate-target', 'flag-epoch-changed', 'flag-ignored', 'flag-lost'];
const stored = new Map();
exports.modes = modes;
exports.handle = function flagFixture(socket, session, method, args, tag) {
  if (!modes.includes(session.mode)) return false;
  if (!stored.has(session.mode)) stored.set(session.mode, new Set(['\\Answered', 'CustomLabel']));
  const flags = stored.get(session.mode);
  const ok = () => socket.write(`${tag} OK Completed\r\n`);
  try {
    if (method === 'SELECT' || method === 'EXAMINE') {
      assert.match(args, /^(?:INBOX|"INBOX")$/);
      session.readOnly = method === 'EXAMINE';
      const after = (session.stores?.length || 0) > 0;
      const missingNext = session.mode === 'flag-no-next' || (after && ['flag-no-next-after', 'flag-compat'].includes(session.mode));
      const validity = after && session.mode === 'flag-epoch-changed' ? 78 : 77;
      // A new arrival changes EXISTS during the operation; it does not change
      // the identity of UID 42 or require a pagination STATUS request.
      socket.write(`* FLAGS (\\Seen \\Flagged)\r\n* ${after ? 52 : 51} EXISTS\r\n* 0 RECENT\r\n* OK [UIDVALIDITY ${validity}] Valid\r\n`);
      if (!missingNext) socket.write(`* OK [UIDNEXT ${after ? 94 : 93}] Next\r\n`);
      if (!session.readOnly) socket.write('* OK [PERMANENTFLAGS (\\Seen \\Flagged)] Permissions\r\n');
      socket.write(`${tag} OK [${session.readOnly ? 'READ-ONLY' : 'READ-WRITE'}] Selected\r\n`);
    } else if (method === 'UID FETCH') {
      assert.match(args, /^42(?::42)? \(UID FLAGS\)$/);
      session.flagFetches = (session.flagFetches || 0) + 1;
      const after = (session.stores?.length || 0) > 0;
      if (['flag-unsolicited', 'flag-compat'].includes(session.mode)) {
        socket.write('* 2 FETCH (UID 43 FLAGS (\\Seen))\r\n');
        // A separate unsolicited flags-only update may have no UID.
        socket.write('* 3 FETCH (FLAGS (\\Flagged))\r\n');
      }
      if (after && session.mode === 'flag-missing-target') {
        socket.write('* 2 FETCH (UID 43 FLAGS (\\Seen))\r\n');
      } else if (after && session.mode === 'flag-missing-flags') {
        socket.write('* 1 FETCH (UID 42)\r\n');
      } else {
        socket.write(`* 1 FETCH (UID 42 FLAGS (${[...flags].join(' ')}))\r\n`);
        if (after && session.mode === 'flag-duplicate-target') socket.write(`* 2 FETCH (UID 42 FLAGS (${[...flags].join(' ')}))\r\n`);
      }
      ok();
    } else if (method === 'UID STORE') {
      assert.equal(session.readOnly, false);
      const match = /^42 ([+-])FLAGS\.SILENT \((\\Seen|\\Flagged)\)$/.exec(args);
      assert.ok(match, 'unexpected flag operation');
      const enabled = match[1] === '+', flag = match[2];
      const mutation = { uid: 42, flag, enabled, before: [...flags], after: [] };
      session.stores ??= []; session.stores.push(mutation);
      if (session.mode !== 'flag-ignored') { if (enabled) flags.add(flag); else flags.delete(flag); }
      mutation.after = [...flags];
      if (session.mode === 'flag-lost') { socket.destroy(); return true; }
      socket.write('* OK Still processing\r\n'); ok();
    } else if (method === 'LOGOUT') {
      socket.end(`* BYE Logging out\r\n${tag} OK Completed\r\n`);
    } else {
      // Flag changes must not fetch a body, list folders or require UIDNEXT.
      throw new Error('unexpected command in flag-only fixture');
    }
  } catch (error) { session.violation = String(error); socket.destroy(); }
  return true;
};
