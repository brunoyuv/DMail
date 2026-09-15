// MPL-2.0: https://mozilla.org/MPL/2.0/
const assert = require('node:assert/strict');
module.exports = (stats, baseline, mailboxes) => {
  const state = stats.nativeAccount = { sessions: 0, unauthorized: 0, selectedAccounts: [], forbidden: 0,
    oversizedBytes: 0, oversizedCancelled: false, postRedirects: 0, mismatchedReplies: 0, violations: [] };
  const base = 'https://localhost:9661/native/';
  const account = Object.values(baseline.accounts)[0];
  const send = (res, body, status = 200) => {
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(body));
  };
  return (req, res) => {
    if (!req.url.startsWith('/native/')) return false;
    const path = req.url.slice('/native/'.length);
    if (path === 'forbidden') { state.forbidden++; send(res, {}); return true; }
    if (req.headers.authorization !== 'Bearer fixture-account-token') {
      state.unauthorized++; send(res, {}, 401); return true;
    }
    if (path.endsWith('-session')) {
      state.sessions++;
      const apiUrl = path === 'cross-origin-session' ? base.replace('localhost', '127.0.0.1') + 'forbidden' :
        path === 'mismatch-session' ? base + 'mismatch-api' : path === 'post-redirect-session' ? base + 'post-redirect-api' : base + 'api';
      send(res, { ...baseline, apiUrl, accounts: {
        a_first: { ...account, name: 'First account' },
        z_selected: { ...account, name: 'Shared account', isPersonal: false }
      }, primaryAccounts: { 'urn:ietf:params:jmap:mail': 'z_selected' } });
      return true;
    }
    if (path === 'redirect') {
      res.writeHead(302, { Location: base.replace('localhost', '127.0.0.1') + 'forbidden' }); res.end(); return true;
    }
    if (path === 'html') { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<p>not JSON</p>'); return true; }
    if (path === 'oversized') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      const chunk = 'x'.repeat(65536);
      const timer = setInterval(() => {
        state.oversizedBytes += chunk.length; res.write(chunk);
        if (state.oversizedBytes >= 8 * 1024 * 1024) { clearInterval(timer); res.end(); }
      }, 2);
      res.on('close', () => { clearInterval(timer); state.oversizedCancelled = !res.writableEnded; });
      return true;
    }
    if (!['api', 'mismatch-api', 'post-redirect-api'].includes(path) || req.method !== 'POST') { send(res, {}, 404); return true; }
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 65536) req.destroy(); });
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        assert.equal(payload.methodCalls.length, 1);
        const [name, args, id] = payload.methodCalls[0];
        assert.equal(name, 'Mailbox/get'); assert.equal(args.accountId, 'z_selected');
        state.selectedAccounts.push(args.accountId);
        if (path === 'post-redirect-api') {
          state.postRedirects++; res.writeHead(307, { Location: base + 'forbidden' }); res.end(); return;
        }
        if (path === 'mismatch-api') state.mismatchedReplies++;
        const list = mailboxes.map(box => ({ ...box, id: 'shared_' + box.id, name: 'Shared ' + box.name }));
        send(res, { sessionState: 'native-state', methodResponses: [[name, { accountId: args.accountId,
          state: 'native-state', list, notFound: [] }, path === 'mismatch-api' ? '00000000-0000-0000-0000-000000000000' : id]] });
      } catch (error) { state.violations.push(error.message); send(res, {}, 400); }
    });
    return true;
  };
};
