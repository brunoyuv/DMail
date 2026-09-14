// MPL-2.0: https://mozilla.org/MPL/2.0/
// Synthetic stateful mailboxes exercise the production Swift change workflows.
const assert = require('node:assert/strict');
module.exports = (stats, baseline, mailboxes, emails) => {
  const core = 'urn:ietf:params:jmap:core', mail = 'urn:ietf:params:jmap:mail';
  const accountId = 'write_account';
  const observations = stats.nativeWrites = { scenarios: {}, violations: [] };
  const states = new Map();
  function stateFor(scenario) {
    if (!states.has(scenario)) {
      const state = { sessions: 0, methods: [], sets: [], applied: 0, version: 0,
        keywords: { '$custom': true }, mailboxIds: { inbox: true, label: true }, external: false };
      if (scenario === 'already') state.mailboxIds.archive = true;
      states.set(scenario, state); observations.scenarios[scenario] = state;
    }
    return states.get(scenario);
  }
  const send = (res, value, status = 200) => {
    res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value));
  };
  return (req, res) => {
    if (!req.url.startsWith('/writes/')) return false;
    const [, , scenario, route] = req.url.split('/');
    const state = stateFor(scenario);
    if (req.headers.authorization !== 'Bearer fixture-write-token') { send(res, {}, 401); return true; }
    if (route === 'session' && req.method === 'GET') {
      state.sessions++;
      send(res, { ...baseline, apiUrl: `https://localhost:9661/writes/${scenario}/api`,
        accounts: { [accountId]: { ...Object.values(baseline.accounts)[0], isReadOnly: scenario === 'readonly' } },
        primaryAccounts: { [mail]: accountId }, capabilities: { ...baseline.capabilities,
          [core]: { ...baseline.capabilities[core], maxSizeRequest: scenario === 'limit' ? 1 : 1024 * 1024 } } });
      return true;
    }
    if (route !== 'api' || req.method !== 'POST') { send(res, {}, 404); return true; }
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 65536) req.destroy(); });
    req.on('end', () => {
      try {
        const payload = JSON.parse(body);
        assert.deepEqual([...payload.using].sort(), [core, mail].sort()); assert.equal(payload.methodCalls.length, 1);
        const [name, args, id] = payload.methodCalls[0];
        assert.match(id, /^[0-9a-f-]{36}$/i); assert.equal(args.accountId, accountId);
        state.methods.push(name);
        const reply = result => send(res, { sessionState: 'session_1', methodResponses: [[name, result, id]] });
        const methodError = type => send(res, { sessionState: 'session_1', methodResponses: [['error', { type }, id]] });
        if (name === 'Mailbox/get') {
          const list = ['inbox', 'archive', 'label', 'extra'].map(id => ({ ...mailboxes[0], id,
            name: id, role: id === 'inbox' || id === 'archive' ? id : null, parentId: null,
            myRights: { ...mailboxes[0].myRights, maySetSeen: true,
              maySetKeywords: !(scenario === 'denied' && id === 'label'),
              mayAddItems: !(scenario === 'archiveDenied' && id === 'archive'), mayRemoveItems: true } }));
          reply({ accountId, list, notFound: [], state: 'boxes_1' });
        } else if (name === 'Email/get') {
          assert.deepEqual(args.ids, ['message']);
          if (['archive', 'stale'].includes(scenario) && state.applied === 1 && !state.external) {
            state.external = true; state.version++;
            if (scenario === 'stale') state.mailboxIds.extra = true;
            else state.keywords['$other'] = true;
          }
          const includeBody = args.fetchTextBodyValues === true;
          const message = { ...emails[1], id: 'message', threadId: 'thread_message', blobId: 'blob_message',
            mailboxIds: state.mailboxIds, keywords: state.keywords,
            textBody: [{ partId: 'text', blobId: 'blob_text', type: 'text/plain', size: 7 }], htmlBody: [], attachments: [],
            bodyValues: includeBody ? { text: { value: 'Fixture', isTruncated: false, isEncodingProblem: false } } : {} };
          reply({ accountId, state: 'v' + state.version, list: [message], notFound: [] });
        } else if (name === 'Email/set') {
          assert.deepEqual(Object.keys(args).sort(), ['accountId', 'ifInState', 'update']);
          assert.deepEqual(Object.keys(args.update), ['message']);
          const patch = args.update.message;
          assert.ok(Object.keys(patch).length > 0);
          for (const [key, value] of Object.entries(patch)) {
            assert.match(key, /^(keywords\/\$(seen|flagged)|mailboxIds\/(inbox|archive))$/);
            assert.ok(value === true || value === null);
          }
          state.sets.push({ patch, ifInState: args.ifInState });
          if (scenario === 'race') { state.version++; state.keywords['$race'] = true; }
          if (args.ifInState !== 'v' + state.version) { methodError('stateMismatch'); return; }
          if (scenario === 'methodReadonly') { methodError('accountReadOnly'); return; }
          const response = { accountId, oldState: args.ifInState, newState: 'v' + state.version,
            created: null, updated: null, destroyed: null, notCreated: null, notUpdated: null, notDestroyed: null };
          if (['forbidden', 'notFound', 'unknown'].includes(scenario)) {
            response.notUpdated = { message: { type: scenario === 'unknown' ? 'futureServerError' : scenario } };
            reply(response); return;
          }
          for (const [path, value] of Object.entries(patch)) {
            const [field, key] = path.split('/');
            if (value === null) delete state[field][key]; else state[field][key] = value;
          }
          state.version++; state.applied++;
          response.newState = 'v' + state.version; response.updated = { message: null };
          if (scenario === 'conflicting') response.notUpdated = { message: { type: 'notFound' } };
          if (scenario === 'badValue') response.updated.message = 'malformed';
          if (scenario === 'lost') { res.destroy(); return; }
          reply(response);
        } else throw Error('Unexpected write fixture method');
      } catch (error) { observations.violations.push(scenario + ': ' + error.message); send(res, {}, 400); }
    });
    return true;
  };
};
