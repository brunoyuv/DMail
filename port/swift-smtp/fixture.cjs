// Synthetic recipients only. This fixture never forwards or delivers mail.
const tls = require('node:tls');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const folder = process.argv[2];
const oauthEnabled = process.env.THUNDERBIRD_SMTP_OAUTH === '1';
const options = { key: fs.readFileSync(`${folder}/server.key`), cert: fs.readFileSync(`${folder}/server.crt`) };
const secureContext = tls.createSecureContext(options);
const stats = { sessions: [], violations: [], remoteLoads: 0, imageLoads: 0,
  uiHoldsStarted: 0, uiHoldsReleased: 0, uiHoldTimeouts: 0, uiResponsiveVerified: 0 };
const sockets = new Set();
let holdNextUi = false;
const pendingUi = new Map();
function connected(socket, startTLS) {
  const record = { startTLS, secure: !startTLS, hello: 0, recipients: [], messages: [], mode: '', closed: false };
  stats.sessions.push(record);
  let buffer = '', data = false, auth = '', payload = [], current = socket;
  const track = s => { sockets.add(s); s.on('error', () => {}); s.on('close', () => { sockets.delete(s); record.closed = true; }); };
  track(socket);
  const write = line => current.write(line + '\r\n');
  function line(value) {
    if (data) {
      if (value === '.') {
        data = false; record.messages.push(payload.map(v => v.startsWith('..') ? v.slice(1) : v).join('\r\n'));
        if (record.mode === 'drop') { current.destroy(); return; }
        if (record.mode === 'data-reject') { write('554 Message rejected'); return; }
        if (record.mode === 'timeout') { return; }
        if (record.mode === 'concurrent') { setTimeout(() => write('250 Message accepted'), 250); return; }
        if (record.mode === 'ui' && holdNextUi) {
          holdNextUi = false; record.acceptanceHeld = true; record.acceptancePending = true;
          stats.uiHoldsStarted++;
          const accept = released => {
            if (!pendingUi.has(record)) return;
            clearTimeout(pendingUi.get(record).timer); pendingUi.delete(record);
            record.acceptancePending = false; record.acceptanceReleased = released;
            if (released) stats.uiHoldsReleased++; else stats.uiHoldTimeouts++;
            write('250 Message accepted');
          };
          // A failed UI assertion cannot leave an unbounded server operation.
          const timer = setTimeout(() => accept(false), 15000);
          pendingUi.set(record, { timer, accept });
          return;
        }
        write('250 Message accepted');
        // Deliberately do not promise a QUIT response after acceptance.
        if (record.mode === 'quit-drop') { current.end(); }
        return;
      }
      payload.push(value); return;
    }
    if (value.startsWith('EHLO ')) {
      record.hello++;
      write('250-fixture.local');
      if (startTLS && !record.secure) { write('250-STARTTLS'); write('250 SIZE 1048576'); }
      else { write(oauthEnabled ? '250-AUTH XOAUTH2 LOGIN PLAIN' : startTLS ? '250-AUTH LOGIN' : '250-AUTH LOGIN PLAIN'); write('250 SIZE 1048576'); }
    } else if (value === 'STARTTLS' && startTLS && !record.secure) {
      write('220 Begin TLS'); current.removeListener('data', read);
      const upgraded = new tls.TLSSocket(current, { isServer: true, secureContext });
      current = upgraded; track(upgraded); buffer = ''; record.secure = true;
      upgraded.on('data', read);
    } else if (value.startsWith('AUTH')) {
      if (!record.secure || (startTLS && record.hello < 2)) { stats.violations.push('authentication before TLS and EHLO'); current.destroy(); return; }
      if (value.startsWith('AUTH XOAUTH2 ') && oauthEnabled) {
        const match = /^user=(oauth-success|oauth-reject)\x01auth=Bearer synthetic-oauth-token\x01\x01$/.exec(Buffer.from(value.slice(13), 'base64').toString());
        if (!match) { stats.violations.push('unexpected OAuth credentials'); current.destroy(); return; }
        record.mode = match[1]; record.oauthResponses = (record.oauthResponses || 0) + 1;
        if (record.mode === 'oauth-reject') { auth = 'oauth-error'; write('334 ' + Buffer.from('{"status":"401"}').toString('base64')); }
        else { write('235 Authenticated'); }
      } else if (oauthEnabled) { stats.violations.push('OAuth fell back to password'); current.destroy(); return; }
      else if (value === 'AUTH LOGIN') { auth = 'username'; write('334 VXNlcm5hbWU6'); }
      else if (value.startsWith('AUTH PLAIN ')) {
        const parts = Buffer.from(value.slice(11), 'base64').toString().split('\0');
        record.mode = parts[1];
        assert.equal(parts[2], 'fixture-password');
        write(record.mode === 'auth-reject' ? '535 Authentication failed' : '235 Authenticated');
      } else { write('504 Unsupported AUTH'); }
    } else if (auth === 'username') { record.mode = Buffer.from(value, 'base64').toString(); auth = 'password'; write('334 UGFzc3dvcmQ6'); }
    else if (auth === 'password') { assert.equal(Buffer.from(value, 'base64').toString(), 'fixture-password'); auth = ''; write('235 Authenticated'); }
    else if (auth === 'oauth-error') {
      record.emptyOAuthErrorReply = value === '';
      if (value !== '') stats.violations.push('OAuth error resent credentials');
      auth = ''; write('535 Authentication failed');
    }
    else if (value === 'MAIL FROM:<sender@example.test>') { write('250 Sender OK'); }
    else if (value.startsWith('RCPT TO:')) {
      record.recipients.push(value);
      write(record.mode === 'recipient-reject' && record.recipients.length === 2 ? '550 No recipient' : '250 Recipient OK');
    } else if (value === 'DATA') { data = true; payload = []; write('354 Send data'); }
    else if (value === 'QUIT') { write('221 Bye'); current.end(); }
    else { stats.violations.push('unexpected command'); write('500 Unexpected command'); }
  }
  function read(chunk) {
    buffer += chunk.toString('utf8');
    let index;
    while ((index = buffer.indexOf('\r\n')) >= 0) {
      const value = buffer.slice(0, index); buffer = buffer.slice(index + 2);
      try { line(value); } catch (error) { stats.violations.push(String(error)); current.destroy(); }
    }
  }
  socket.on('data', read); write('220 fixture.local ESMTP');
}
const implicit = tls.createServer(options, socket => connected(socket, false)).listen(9771, '127.0.0.1');
implicit.on('tlsClientError', () => {});
const explicit = net.createServer(socket => connected(socket, true)).listen(9772, '127.0.0.1');
const sent = require('./sent-fixture.cjs')(options, stats, sockets);
const jmapFixture = require('../swift-jmap/fixture.cjs')(stats);
const jmap = https.createServer(options, (req, res) => { if (!jmapFixture(req, res)) { res.writeHead(404); res.end(); } }).listen(9661, '127.0.0.1');
const control = http.createServer((request, response) => {
  if (request.url === '/stats') { response.end(JSON.stringify(stats)); }
  else if (request.url === '/health') { response.end('ready'); }
  else if (request.url === '/ui/hold' && request.method === 'POST') {
    if (holdNextUi || pendingUi.size) { response.writeHead(409); response.end('already held'); }
    else { holdNextUi = true; response.end('ready'); }
  }
  else if (request.url === '/ui/release' && request.method === 'POST') {
    holdNextUi = false;
    for (const pending of Array.from(pendingUi.values())) pending.accept(true);
    response.end('released');
  }
  else if (request.url === '/ui/responsive' && request.method === 'POST') {
    if (pendingUi.size !== 1) { response.writeHead(409); response.end('no pending acknowledgement'); }
    else { stats.uiResponsiveVerified++; response.end('verified'); }
  }
  else if (request.url === '/picture.png') { stats.imageLoads++; response.writeHead(200, {'Content-Type': 'image/png', 'Cache-Control': 'no-store'}); response.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=', 'base64')); }
  else { stats.remoteLoads++; response.end('TRACKER SHOULD BE BLOCKED'); }
}).listen(9770, '127.0.0.1');
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  for (const pending of pendingUi.values()) clearTimeout(pending.timer);
  pendingUi.clear();
  for (const socket of sockets) socket.destroy();
  for (const server of [implicit, explicit, control, jmap, sent]) server.close();
});
