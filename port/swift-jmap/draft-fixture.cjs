// MPL-2.0: https://mozilla.org/MPL/2.0/
const assert = require('node:assert/strict');
module.exports = (stats, baseline, mailboxes, emails) => {
  const core = 'urn:ietf:params:jmap:core', mail = 'urn:ietf:params:jmap:mail', accountId = 'draft_account';
  const observations = stats.nativeDrafts = { scenarios: {}, violations: [], submissions: 0 };
  const saved = new Map();
  const send = (res, value, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
  return (req, res) => {
    if (!req.url.startsWith('/drafts/')) return false;
    const [, , scenario, route] = req.url.split('/');
    const state = observations.scenarios[scenario] ??= { sessions: 0, creates: 0, applied: 0, reads: 0, bodyBytes: 0 };
    if (req.headers.authorization !== 'Bearer fixture-draft-token') { send(res, {}, 401); return true; }
    if (route === 'session' && req.method === 'GET') {
      state.sessions++;
      send(res, { ...baseline, apiUrl: `https://localhost:9661/drafts/${scenario}/api`,
        accounts: { [accountId]: { ...Object.values(baseline.accounts)[0], isReadOnly: scenario === 'readonly' } },
        primaryAccounts: { [mail]: accountId }, capabilities: { ...baseline.capabilities,
          [core]: { ...baseline.capabilities[core], maxSizeRequest: scenario === 'limit' ? 512 : 1024 * 1024 } } });
      return true;
    }
    if (route !== 'api' || req.method !== 'POST') { send(res, {}, 404); return true; }
    const chunks = []; let received = 0;
    req.on('data', chunk => {
      received += chunk.length;
      if (received > 4 * 1024 * 1024) { req.destroy(); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        assert.deepEqual([...payload.using].sort(), [core, mail].sort()); assert.equal(payload.methodCalls.length, 1);
        const [name, args, id] = payload.methodCalls[0];
        assert.match(id, /^[0-9a-f-]{36}$/i); assert.equal(args.accountId, accountId);
        if (name.startsWith('EmailSubmission/')) observations.submissions++;
        const reply = result => send(res, { sessionState: 'session_1', methodResponses: [[name, result, id]] });
        if (name === 'Mailbox/get') {
          const draftBox = { ...mailboxes[0], id: 'box_drafts', name: 'Saved work', role: 'drafts',
            myRights: { ...mailboxes[0].myRights, mayAddItems: scenario !== 'denied' } };
          const list = scenario === 'missing' ? [] : scenario === 'ambiguous' ? [draftBox, { ...draftBox, id: 'box_other' }] : [draftBox];
          reply({ accountId, state: 'boxes_1', list, notFound: [] });
        } else if (name === 'Email/set') {
          assert.deepEqual(Object.keys(args).sort(), ['accountId', 'create']); assert.deepEqual(Object.keys(args.create), ['draft']);
          state.creates++;
          const draft = args.create.draft;
          assert.deepEqual(draft.mailboxIds, { box_drafts: true }); assert.deepEqual(draft.keywords, { '$draft': true, '$seen': true });
          assert.deepEqual(draft.textBody, [{ partId: 'body', type: 'text/plain' }]);
          assert.deepEqual(Object.keys(draft.bodyValues), ['body']);
          assert.equal(draft.bodyValues.body.isTruncated, false); assert.equal(draft.bodyValues.body.isEncodingProblem, false);
          state.bodyBytes = Buffer.byteLength(draft.bodyValues.body.value);
          assert.ok(state.bodyBytes <= 256 * 1024);
          if (scenario === 'snapshot') {
            assert.equal(draft.subject, 'Draft 世界');
            assert.ok(draft.bodyValues.body.value === '界'.repeat(50000), 'Unicode body must survive upload unchanged');
            assert.deepEqual(draft.from, [{ name: 'Author', email: 'author@example.test' }]);
            assert.deepEqual(draft.to, [{ name: 'Unfinished', email: 'name<unfinished' }]);
            assert.deepEqual(draft.cc, [{ name: 'Cc', email: 'cc@example.test' }]);
            assert.deepEqual(draft.bcc, [{ name: 'Bcc', email: 'bcc@example.test' }]);
            assert.deepEqual(draft.replyTo, [{ name: 'Reply', email: 'reply@example.test' }]);
            assert.deepEqual(draft.inReplyTo, ['parent@example.test']); assert.deepEqual(draft.references, ['root@example.test', 'parent@example.test']);
          }
          if (scenario === 'empty') {
            for (const key of ['from', 'to', 'cc', 'bcc', 'replyTo', 'inReplyTo', 'references']) assert.equal(draft[key], null);
            assert.equal(draft.subject, ''); assert.equal(draft.bodyValues.body.value, '');
          }
          const response = { accountId, oldState: 'v0', newState: 'v1', created: null, updated: null, destroyed: null,
            notCreated: null, notUpdated: null, notDestroyed: null };
          const rejections = { reject: 'forbidden', quota: 'overQuota', large: 'tooLarge', invalid: 'invalidProperties', future: 'futureSetError' };
          if (rejections[scenario]) { response.notCreated = { draft: { type: rejections[scenario] } }; reply(response); return; }
          if (scenario === 'method') { send(res, { sessionState: 'session_1', methodResponses: [['error', { type: 'serverFail' }, id]] }); return; }
          if (scenario === 'http') { send(res, {}, 500); return; }
          const created = { id: 'draft_1', blobId: 'blob_draft_1', threadId: 'thread_draft_1', size: state.bodyBytes + 100 };
          saved.set(scenario, { draft, created }); state.applied++;
          response.created = { draft: { ...created } };
          if (scenario === 'malformed') delete response.created.draft.threadId;
          if (scenario === 'conflicting') response.notCreated = { draft: { type: 'forbidden' } };
          if (scenario === 'lost') { res.destroy(); return; }
          reply(response);
        } else if (name === 'Email/get') {
          state.reads++;
          const entry = saved.get(scenario); assert.ok(entry); assert.deepEqual(args.ids, ['draft_1']);
          const message = { ...emails[1], ...entry.draft, ...entry.created, preview: 'Draft preview', hasAttachment: false,
            textBody: [{ partId: 'body', blobId: 'blob_body', size: state.bodyBytes, type: 'text/plain' }], htmlBody: [], attachments: [] };
          reply({ accountId, state: 'v1', list: [message], notFound: [] });
        } else throw Error('Unexpected draft method');
      } catch (error) { observations.violations.push(scenario + ': ' + error.message); send(res, {}, 400); }
    });
    return true;
  };
};
