// MPL-2.0: https://mozilla.org/MPL/2.0/
// Serve upstream test vectors over local TLS, with only endpoint and membership
// normalization. This fixture performs no requests to external mail services.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = path.resolve(__dirname, '../../.tools/swift-probe/native-jmap/source/Core/Tests/JMAPTests');
function vector(name) {
  const swift = fs.readFileSync(path.join(source, `${name}Tests.swift`), 'utf8');
  const match = swift.match(/private let data: Data = """\n([\s\S]*?)\n"""\.data\(using: \.utf8\)!/);
  assert.ok(match, `Missing pinned ${name} test vector`);
  // These pinned vectors contain no Swift string escapes or interpolation.
  assert.ok(!match[1].includes('\\'), 'Vector requires explicit Swift string decoding');
  return JSON.parse(match[1]);
}
const session = vector('Session');
const mailboxes = vector('Mailbox');
const inbox = mailboxes.find(m => m.role === 'inbox');
const emails = vector('Email').map(email => ({ ...email, mailboxIds: { [inbox.id]: true } }));
const accountId = session.primaryAccounts['urn:ietf:params:jmap:mail'];
const CORE = 'urn:ietf:params:jmap:core';
const MAIL = 'urn:ietf:params:jmap:mail';
const send = (res, body, status = 200) => {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(body));
};
module.exports = function makeJmapFixture(stats) {
  const accountFixture = require('./account-fixture.cjs')(stats, session, mailboxes);
  const readerFixture = require('./reader-fixture.cjs')(stats, session, emails);
  const writeFixture = require('./write-fixture.cjs')(stats, session, mailboxes, emails);
  const draftFixture = require('./draft-fixture.cjs')(stats, session, mailboxes, emails);
  const state = stats.jmap = { sessions: 0, unauthorized: 0, malformed: 0, calls: [], violations: [], created: [], updated: [], destroyed: [] };
  let folder;
  return (req, res) => {
    if (accountFixture(req, res)) return true;
    if (readerFixture(req, res)) return true;
    if (writeFixture(req, res)) return true;
    if (draftFixture(req, res)) return true;
    if (!req.url.startsWith('/jmap/')) return false;
    if (!['Bearer native-jmap-fixture-token', 'Bearer malformed-fixture-token'].includes(req.headers.authorization)) {
      state.unauthorized++; send(res, { error: 'Unauthorized' }, 401); return true;
    }
    if (req.url === '/jmap/session' && req.method === 'GET') {
      state.sessions++;
      send(res, { ...session, apiUrl: 'https://localhost:9661/jmap/api',
        eventSourceUrl: 'https://localhost:9661/jmap/events',
        downloadUrl: 'https://localhost:9661/jmap/download/{accountId}/{blobId}/{name}?type={type}',
        uploadUrl: 'https://localhost:9661/jmap/upload/{accountId}' });
      return true;
    }
    if (req.url !== '/jmap/api' || req.method !== 'POST') { send(res, {}, 404); return true; }
    let body = '';
    req.on('data', chunk => { body += chunk; if (body.length > 65536) req.destroy(); });
    req.on('end', () => {
      try {
        assert.match(req.headers['content-type'], /^application\/json/);
        assert.equal(req.headers.accept, 'application/json');
        const payload = JSON.parse(body);
        assert.deepEqual([...payload.using].sort(), [CORE, MAIL].sort());
        assert.equal(payload.methodCalls.length, 1);
        const [name, args, id] = payload.methodCalls[0];
        assert.match(id, /^[0-9a-f-]{36}$/i);
        assert.equal(args.accountId, accountId);
        state.calls.push(name);
        const result = { accountId, state: 'fixture-1', notFound: [] };
        if (name === 'Mailbox/get') {
          if (req.headers.authorization === 'Bearer malformed-fixture-token') {
            state.malformed++; result.list = 'invalid-list';
          } else result.list = mailboxes;
        } else if (name === 'Email/query') {
          assert.deepEqual(args.filter, { operator: 'OR', conditions: [{ inMailbox: inbox.id }] });
          Object.assign(result, { ids: emails.map(e => e.id), position: 0, total: emails.length, queryState: 'fixture-1' });
        } else if (name === 'Email/get') {
          result.list = args.ids.map(id => emails.find(e => e.id === id));
          assert.ok(result.list.every(Boolean));
        } else if (name === 'Thread/get') {
          result.list = args.ids.map(id => ({ id, emailIds: emails.filter(e => e.threadId === id).map(e => e.id) }));
        } else if (name === 'Mailbox/set') {
          result.oldState = 'fixture-0'; result.newState = 'fixture-1';
          if (args.create) {
            assert.deepEqual(args.create, { 'new-folder': { name: 'Private mailbox 84631', isSubscribed: true } });
            folder = { id: 'created-folder', ...args.create['new-folder'] };
            state.created.push(folder.id); result.created = { 'new-folder': { id: folder.id } };
          } else if (args.update) {
            assert.ok(folder); assert.deepEqual(args.update, { [folder.id]: { name: 'Private renamed 84631', isSubscribed: true } });
            state.updated.push(folder.id); result.updated = { [folder.id]: null };
          } else {
            assert.ok(folder); assert.deepEqual(args.destroy, [folder.id]);
            state.destroyed.push(folder.id); result.destroyed = [folder.id]; folder = undefined;
          }
        } else throw Error(`Unexpected method ${name}`);
        send(res, { sessionState: 'fixture-1', methodResponses: [[name, result, id]] });
      } catch (error) { state.violations.push(error.message); send(res, { error: 'Invalid fixture request' }, 400); }
    });
    return true;
  };
};
