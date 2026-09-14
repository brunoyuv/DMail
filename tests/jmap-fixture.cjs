// Synthetic, loopback-only server for on-device transport tests. No real mail
// credentials are read and no external requests or email submissions are made.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const CORE = 'urn:ietf:params:jmap:core';
const MAIL = 'urn:ietf:params:jmap:mail';
const stats = { apiCalls: [], patches: [], redirectFollowed: 0, tlsRejected: 0, lostWriteResponses: 0 };
const keywords = { 'fixture-label': true };
const mailboxIds = { inbox: true, label: true };
const drafts = new Map();
stats.draftCreates = [];
stats.lostDraftResponses = 0;
let loseNextDraftResponse = false;
let offline = false;
stats.offlineReads = 0;
stats.offlineApiRequests = 0;
stats.mailboxIds = mailboxIds;
let emailVersion = 1;
let loseNextWriteResponse = false;
const send = (res, value, status = 200) => {
  res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value));
};
function handler(req, res) {
  if (req.url === '/stats') { return send(res, stats); }
  if (req.url === '/health') { return send(res, { ready: true }); }
  if (req.url === '/redirect') { res.writeHead(302, { Location: '/must-not-follow' }); return res.end(); }
  if (req.url === '/must-not-follow') { stats.redirectFollowed++; return send(res, {}); }
  if (req.url === '/large') { res.writeHead(200); return res.end('x'.repeat(65536)); }
  if (req.url === '/unicode') {
    const bytes = Buffer.from('鸿蒙 📬');
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.write(bytes.subarray(0, 1));
    return setTimeout(() => res.end(bytes.subarray(1)), 20);
  }
  if (req.url === '/unauthorized' || req.headers.authorization !== 'Bearer fixture-only-token') {
    return send(res, { error: 'fixture authentication failure' }, 401);
  }
  if (req.method === 'POST' && ['/offline', '/online'].includes(req.url)) {
    offline = req.url === '/offline'; return send(res, { offline });
  }
  if (offline && ['/api', '/session'].includes(req.url)) {
    if (req.method === 'POST') { stats.offlineApiRequests++; } else { stats.offlineReads++; }
    return send(res, { error: 'Temporarily unavailable' }, 503);
  }
  if (req.url === '/session') {
    return send(res, { capabilities: { [CORE]: { maxObjectsInGet: 2 }, [MAIL]: {} },
      accounts: { personal: { name: 'Fixture', isPersonal: true, isReadOnly: false, accountCapabilities: { [MAIL]: {} } } },
      primaryAccounts: { [MAIL]: 'personal' }, state: 's1', apiUrl: 'https://fixture.example/api' });
  }
  if (req.url === '/lose-next-write-response' && req.method === 'POST') {
    loseNextWriteResponse = true; return send(res, { ready: true });
  }
  if (req.url === '/lose-next-draft-response' && req.method === 'POST') {
    loseNextDraftResponse = true; return send(res, { ready: true });
  }
  if (req.url !== '/api' || req.method !== 'POST') { return send(res, {}, 404); }
  let body = '';
  req.on('data', chunk => { body += chunk; if (body.length > 65536) { req.destroy(); } });
  req.on('end', () => {
    try {
      const payload = JSON.parse(body);
      const [name, args, callId] = payload.methodCalls[0];
      stats.apiCalls.push(name);
      if (args.accountId !== 'personal') { return send(res, {}, 400); }
      let result;
      if (name === 'Mailbox/get') {
        result = { state: `m${emailVersion}`, notFound: [], list: ['inbox', 'archive', 'label', 'drafts'].map((id, index) => ({
          id, name: ['Inbox', 'Archive', 'Project', 'Drafts'][index], role: id === 'label' ? null : id, parentId: null,
          sortOrder: index, totalEmails: id === 'drafts' ? drafts.size : mailboxIds[id] ? 1 : 0,
          unreadEmails: mailboxIds[id] && !keywords.$seen ? 1 : 0,
          myRights: { maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true }
        })) };
      } else if (name === 'Email/query') {
        if (args.filter.inMailbox === 'drafts') {
          return send(res, { sessionState: 's1', methodResponses: [[name, { accountId: args.accountId,
            queryState: `q${emailVersion}`, position: args.position, total: drafts.size,
            ids: Array.from(drafts.keys()).slice(args.position, args.position + args.limit) }, callId]] });
        }
        const matches = mailboxIds[args.filter.inMailbox] === true;
        result = { queryState: `q${emailVersion}`, position: 0, total: matches ? 1 : 0, ids: matches ? ['e1'] : [] };
      } else if (name === 'Email/get') {
        const mail = { id: 'e1', threadId: 't1', messageId: ['fixture@example.com'], mailboxIds,
          keywords, from: [{ name: 'Fixture', email: 'fixture@example.com' }], to: null,
          replyTo: [{ name: null, email: 'reply@example.com' }], subject: 'Native JMAP fixture',
          preview: 'Hello from the fixture.', receivedAt: '2026-09-13T00:00:00Z', hasAttachment: false };
        if (args.fetchTextBodyValues) {
          mail.textBody = [{ partId: 'p1', type: 'text/plain' }]; mail.htmlBody = [];
          mail.bodyValues = { p1: { value: 'Hello from the fixture. 鸿蒙 📬', isTruncated: false, isEncodingProblem: false } };
        }
        const list = args.ids.map(id => id === 'e1' ? mail : drafts.get(id)).filter(Boolean);
        result = { state: `e${emailVersion}`, notFound: args.ids.filter(id => id !== 'e1' && !drafts.has(id)), list };
      } else if (name === 'Email/set') {
        if (args.create) {
          if (JSON.stringify(Object.keys(args).sort()) !== '["accountId","create"]' ||
            JSON.stringify(Object.keys(args.create)) !== '["draft"]') { return send(res, {}, 400); }
          const draft = args.create.draft;
          if (JSON.stringify(draft.mailboxIds) !== '{"drafts":true}' ||
            JSON.stringify(draft.keywords) !== '{"$draft":true,"$seen":true}' || draft.textBody.length !== 1 ||
            draft.textBody[0].type !== 'text/plain' || draft.textBody[0].partId !== 'body' ||
            typeof draft.bodyValues.body.value !== 'string' || draft.bodyValues.body.isTruncated !== false ||
            draft.bodyValues.body.isEncodingProblem !== false) { return send(res, {}, 400); }
          stats.draftCreates.push(draft);
          const id = `draft${drafts.size + 1}`;
          drafts.set(id, { ...draft, id, threadId: `thread-${id}`, messageId: [`${id}@example.com`],
            preview: draft.bodyValues.body.value.slice(0, 100), receivedAt: '2026-09-13T00:00:00Z',
            hasAttachment: false, htmlBody: [] });
          const oldState = `e${emailVersion++}`;
          if (loseNextDraftResponse) {
            loseNextDraftResponse = false; stats.lostDraftResponses++; req.socket.destroy(); return;
          }
          return send(res, { sessionState: 's1', methodResponses: [[name, { accountId: args.accountId,
            oldState, newState: `e${emailVersion}`, notCreated: null, created: { draft: {
              id, blobId: `blob-${id}`, threadId: `thread-${id}`, size: Buffer.byteLength(JSON.stringify(draft))
            } } }, callId]] });
        }
        if (!['["accountId","update"]', '["accountId","ifInState","update"]'].includes(JSON.stringify(Object.keys(args).sort())) ||
          JSON.stringify(Object.keys(args.update)) !== '["e1"]') { return send(res, {}, 400); }
        const patch = args.update.e1;
        const paths = Object.keys(patch);
        const moving = paths.every(path => ['mailboxIds/inbox', 'mailboxIds/archive'].includes(path));
        if ((!moving && (paths.length !== 1 || !['keywords/$seen', 'keywords/$flagged'].includes(paths[0]))) ||
          paths.length < 1 || paths.length > 2 || paths.some(path => patch[path] !== true && patch[path] !== null)) { return send(res, {}, 400); }
        if (moving && args.ifInState !== `e${emailVersion}`) {
          return send(res, { sessionState: 's1', methodResponses: [['error', { type: 'stateMismatch' }, callId]] });
        }
        stats.patches.push(patch);
        for (const path of paths) {
          const [property, key] = path.split('/'); const target = property === 'mailboxIds' ? mailboxIds : keywords;
          if (patch[path] === null) { delete target[key]; } else { target[key] = true; }
        }
        const oldState = `e${emailVersion++}`;
        if (loseNextWriteResponse) {
          loseNextWriteResponse = false; stats.lostWriteResponses++;
          req.socket.destroy(); return;
        }
        result = { oldState, newState: `e${emailVersion}`, updated: { e1: null }, notUpdated: null };
      } else { return send(res, {}, 400); }
      send(res, { sessionState: 's1', methodResponses: [[name, { accountId: args.accountId, ...result }, callId]] });
    } catch (_) { send(res, {}, 400); }
  });
}
const server = http.createServer(handler);
const tls = https.createServer({ key: fs.readFileSync(process.argv[2]), cert: fs.readFileSync(process.argv[3]) }, handler);
tls.on('tlsClientError', () => stats.tlsRejected++);
server.listen(9555, '127.0.0.1'); tls.listen(9556, '127.0.0.1');
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => { server.closeAllConnections(); tls.closeAllConnections(); server.close(); tls.close(); });
}
