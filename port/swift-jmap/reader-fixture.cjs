// MPL-2.0: https://mozilla.org/MPL/2.0/
// Extend pinned upstream vectors with reader/pagination cases; no real account.
const assert = require('node:assert/strict');
module.exports = (stats, baseline, emails) => {
  const state = stats.nativeReader = { sessions: 0, queries: [], gets: [], violations: [] };
  const core = 'urn:ietf:params:jmap:core', mail = 'urn:ietf:params:jmap:mail';
  const accountId = 'reader_account';
  const send = (res, body, status = 200) => {
    res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body));
  };
  const part = (id, type) => ({ partId: id, blobId: 'blob_' + id, size: 64, type });
  function message(id, includeBody) {
    const value = { ...emails[1], id, threadId: 'thread_' + id, blobId: 'blob_' + id,
      mailboxIds: { inbox: true, label: true }, keywords: { '$seen': true, '$custom': true },
      receivedAt: '2026-09-13T08:12:34.125Z', subject: 'Reader ' + id,
      preview: 'Preview is not the message body', hasAttachment: true,
      replyTo: [{ name: 'Reply Person', email: 'reply@example.test' }],
      textBody: [part('plain1', 'text/plain'), part('plain2', 'text/plain')], htmlBody: [part('html', 'text/html')],
      attachments: [part('attachment', 'application/pdf')],
      bodyValues: includeBody ? {
        plain1: { value: 'Hello 世界', isTruncated: false, isEncodingProblem: true },
        plain2: { value: 'Second part', isTruncated: true, isEncodingProblem: false },
        html: { value: '<h1>JMAP HTML 世界</h1>', isTruncated: false, isEncodingProblem: false }
      } : {} };
    if (id === 'html') { value.textBody = []; value.bodyValues = includeBody ? { html: value.bodyValues.html } : {}; }
    if (id === 'badbody') delete value.bodyValues.plain2;
    if (id === 'badDate') value.receivedAt = '2026-02-30T08:12:34Z';
    if (id === 'tooLarge') value.bodyValues.plain1.value = '界'.repeat(90_000);
    if (id === 'long') value.bodyValues.plain1.value = '界'.repeat(40_000);
    return value;
  }
  return (req, res) => {
    if (!req.url.startsWith('/reader/')) return false;
    if (req.headers.authorization !== 'Bearer fixture-reader-token') { send(res, {}, 401); return true; }
    if (req.url === '/reader/session' && req.method === 'GET') {
      state.sessions++;
      send(res, { ...baseline, apiUrl: 'https://localhost:9661/reader/api',
        accounts: { [accountId]: Object.values(baseline.accounts)[0] }, primaryAccounts: { [mail]: accountId },
        capabilities: { ...baseline.capabilities, [core]: { ...baseline.capabilities[core], maxObjectsInGet: 2 } } });
      return true;
    }
    if (req.url !== '/reader/api' || req.method !== 'POST') { send(res, {}, 404); return true; }
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 65536) req.destroy(); });
    req.on('end', () => {
      try {
        const request = JSON.parse(body);
        assert.deepEqual([...request.using].sort(), [core, mail].sort());
        assert.equal(request.methodCalls.length, 1);
        const [name, args, id] = request.methodCalls[0];
        assert.match(id, /^[0-9a-f-]{36}$/i); assert.equal(args.accountId, accountId);
        const result = { accountId, state: 'emails_1', notFound: [] };
        if (name === 'Email/query') {
          const mailbox = args.filter.conditions[0].inMailbox;
          assert.deepEqual(args.filter, { operator: 'OR', conditions: [{ inMailbox: mailbox }] });
          assert.deepEqual(args.sort, [{ property: 'receivedAt', isAscending: false }]);
          assert.equal(args.limit, 2); assert.equal(args.calculateTotal, true); assert.equal(args.collapseThreads, false);
          state.queries.push([mailbox, args.position]);
          let ids = [], total = 3;
          if (mailbox === 'paged') ids = args.position === 0 ? ['first', 'deleted'] : args.position === 2 ? ['last'] : [];
          else if (mailbox === 'ordered') { ids = ['first', 'last']; total = 2; }
          else if (mailbox === 'unknown') { ids = args.position === 0 ? ['first'] : []; total = undefined; }
          else if (mailbox === 'changed' || mailbox === 'wrongPosition') { ids = ['first']; total = 1; }
          else throw Error('Unexpected mailbox');
          Object.assign(result, { ids, total, position: mailbox === 'wrongPosition' ? 1 : args.position,
            queryState: mailbox === 'changed' ? 'query_2' : 'query_1' });
        } else if (name === 'Email/get') {
          const includeBody = args.fetchTextBodyValues === true;
          state.gets.push({ ids: args.ids, includeBody });
          if (includeBody) {
            assert.deepEqual(args.bodyProperties, ['partId', 'blobId', 'size', 'type']);
            assert.equal(args.maxBodyValueBytes, 256 * 1024);
            assert.equal(args.fetchHTMLBodyValues, true); assert.equal(args.fetchAllBodyValues, false);
          }
          result.notFound = args.ids.filter(id => id === 'deleted' || id === 'missing');
          result.list = args.ids.filter(id => !result.notFound.includes(id)).reverse().map(id => message(id, includeBody));
          if (args.ids.includes('duplicate')) result.list.push(result.list[0]);
        } else throw Error('Unexpected reader method');
        send(res, { sessionState: 'session_1', methodResponses: [[name, result, id]] });
      } catch (error) { state.violations.push(error.message); send(res, {}, 400); }
    });
    return true;
  };
};
