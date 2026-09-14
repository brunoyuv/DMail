// Synthetic, loopback-only IMAP server. Never record credential values.
const tls = require('node:tls');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
const accountFixture = require('./account-fixture.cjs');
const flagFixture = require('./flag-fixture.cjs');
const inboxCheckFixture = require('./inbox-check-fixture.cjs');
const inboxWatchFixture = require('./inbox-watch-fixture.cjs');
const idleEnabled = process.env.THUNDERBIRD_IMAP_IDLE === '1';
const oauthEnabled = process.env.THUNDERBIRD_IMAP_OAUTH === '1';
const corpus = process.env.THUNDERBIRD_MAIL_CORPUS === '1' ? require('../mail-corpus/fixture.cjs') : null;
const stats = { connections: {}, sessions: [], violations: [], tlsErrors: 0, active: 0 };
const bodyText = 'Hello from Thunderbird IMAP. 日本語 ✓';
const mime = Buffer.from([
  'From: Sender <sender@example.test>', 'To: Reader <reader@example.test>',
  'Subject: Native IMAP fixture', 'MIME-Version: 1.0',
  'Content-Type: text/plain; charset=utf-8', 'Content-Transfer-Encoding: base64',
  '', Buffer.from(bodyText).toString('base64'), ''
].join('\r\n'));
const envelope = '("Sun, 13 Sep 2026 10:00:00 +0000" "Native IMAP fixture" ' +
  '(("Sender" NIL "sender" "example.test")) NIL NIL ' +
  '(("Reader" NIL "reader" "example.test")) NIL NIL NIL "<fixture@example.test>")';
http.createServer((req, res) => {
  if (req.url === '/health') return res.end('ready');
  if (req.url === '/stats') return res.end(JSON.stringify(stats));
  if (req.url === '/corpus/pdf' && corpus) return res.end(JSON.stringify(corpus.pdf));
  if (req.url === '/corpus' && corpus) return res.end(JSON.stringify(corpus.index));
  if (req.url?.match(/^\/corpus\/batch\/[0-2]$/) && corpus && req.method === 'POST') {
    if (stats.active !== 0) return res.writeHead(409).end('Connections still active');
    corpus.selectBatch(Number(req.url.slice(-1)));return res.end('ready');
  }
  if (req.url === '/corpus/result' && corpus && req.method === 'POST') {
    let body='';req.on('data',data=>{body+=data;if(body.length>1048576)req.destroy();});
    req.on('end',()=>{const incoming=JSON.parse(body);
      const names=new Set(incoming.map(item=>item.name));
      stats.corpusResults=[...(stats.corpusResults||[]).filter(item=>!names.has(item.name)),...incoming];res.end('saved');});return;
  }
  res.writeHead(404).end();
}).listen(9760, '127.0.0.1');
for (const [name, port] of [['server', 9761], ['untrusted', 9762], ['wrong', 9763], ['pinwrong', 9764], ['plainlist', 9765], ...(oauthEnabled ? [['oauthnone', 9766]] : [])]) {
  const certificateName = ['plainlist', 'oauthnone'].includes(name) ? 'server' : name;
  const server = tls.createServer({key: fs.readFileSync(path.join(dir, certificateName + '.key')),
    cert: fs.readFileSync(path.join(dir, certificateName + '.crt'))}, socket => {
    const session = { server: name, mode: '', commands: [], closed: false, fetches: 0 };
    stats.sessions.push(session); stats.active++;
    let buffer = '', authenticated = false, selected = false;
    let oauthTag = '', oauthError = false;
    const oauthResponse = encoded => {
      session.oauthResponses = (session.oauthResponses || 0) + 1;
      const value = Buffer.from(encoded, 'base64').toString('utf8');
      const valid = /^user=(oauth-reader|oauth-reject)\x01auth=Bearer synthetic-oauth-token\x01\x01$/.exec(value);
      if (!valid) { stats.violations.push('unexpected OAuth fixture credentials'); socket.destroy(); return; }
      session.oauthMode = valid[1];
      if (valid[1] === 'oauth-reject') {
        oauthError = true;
        socket.write('+ ' + Buffer.from('{"status":"401","schemes":"bearer"}').toString('base64') + '\r\n');
      } else {
        authenticated = true; session.mode = 'account';
        socket.write(`${oauthTag} OK authenticated\r\n`); oauthTag = '';
      }
    };
    socket.on('error', () => {});
    socket.on('close', () => { session.closed = true; stats.active--; });
    socket.write('* OK Thunderbird local fixture\r\n');
    socket.on('data', data => {
      buffer += data.toString('ascii');
      if (buffer.length > 16384) { stats.violations.push('oversized command'); socket.destroy(); return; }
      let end;
      while ((end = buffer.indexOf('\r\n')) >= 0) {
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 2);
        if (oauthTag) {
          if (oauthError) {
            session.emptyOAuthErrorReply = line === '';
            if (line !== '') stats.violations.push('OAuth error resent credentials');
            socket.write(`${oauthTag} NO authentication failed\r\n`); oauthTag = ''; oauthError = false;
          } else { oauthResponse(line); }
          continue;
        }
        if (line === 'DONE' && idleEnabled && inboxWatchFixture.done(socket, session)) { session.commands.push('DONE'); continue; }
        const match = /^(\S+) (CAPABILITY|AUTHENTICATE|LOGIN|LIST|SELECT|EXAMINE|STATUS|UID FETCH|UID STORE|FETCH|IDLE|LOGOUT)(?: (.*))?$/i.exec(line);
        if (!match) { stats.violations.push('unexpected command'); socket.destroy(); return; }
        const [, tag, command, args = ''] = match;
        const method = command.toUpperCase(); session.commands.push(method);
        const ok = () => socket.write(`${tag} OK Completed\r\n`);
        if (method === 'CAPABILITY') {
          const statusCapabilities = session.mode === 'status-basic-only' ? ' UIDPLUS CONDSTORE' : '';
          const oauthCapabilities = oauthEnabled && name !== 'oauthnone' ? ` AUTH=XOAUTH2${name === 'plainlist' ? '' : ' SASL-IR'}` : '';
          socket.write(`* CAPABILITY IMAP4rev1${name === 'plainlist' ? '' : ' LIST-EXTENDED LIST-STATUS'}${oauthCapabilities}${statusCapabilities}${idleEnabled && authenticated && name !== 'plainlist' ? ' IDLE' : ''}\r\n`); ok();
        } else if (method === 'AUTHENTICATE') {
          const auth = /^XOAUTH2(?: ([A-Za-z0-9+/]+=*))?$/.exec(args);
          if (!oauthEnabled || name === 'oauthnone' || !auth || (name === 'plainlist' && auth[1])) {
            stats.violations.push('unexpected OAuth mechanism'); socket.destroy(); return;
          }
          oauthTag = tag; session.initialOAuthResponse = !!auth[1];
          if (auth[1]) oauthResponse(auth[1]); else socket.write('+ \r\n');
        } else if (method === 'LOGIN') {
          if (oauthEnabled) { stats.violations.push('OAuth fell back to LOGIN'); socket.destroy(); return; }
          const credentials = /^(?:"([a-z-]+)"|([a-z-]+)) (?:"fixture-password"|fixture-password)$/.exec(args);
          if (!credentials) { stats.violations.push('unexpected fixture credentials'); socket.destroy(); return; }
          session.mode = credentials[1] || credentials[2];
          if (![...flagFixture.modes, ...inboxCheckFixture.modes, ...inboxWatchFixture.modes, 'encoding', 'corpus', 'html', 'gesture', 'status-basic-only', 'status-fail', 'status-drop', 'cancel', 'list-retry', 'reader', 'bad', 'stall', 'drop', 'oversized', 'wrongtag', 'no-next', 'next-changed', 'next-missing', 'next-count', 'account', 'epoch', 'changed', 'missing', 'wronguid', 'writer', 'readonly', 'limited', 'noflags', 'wildcard', 'omitted', 'storefail', 'lost', 'ignored'].includes(session.mode)) {
            stats.violations.push('unknown scenario'); socket.destroy(); return;
          }
          if (session.mode === 'bad') socket.write(`${tag} NO [AUTHENTICATIONFAILED] Rejected\r\n`);
          else { authenticated = true; ok(); }
        } else if (!authenticated) {
          stats.violations.push('command before authentication'); socket.destroy(); return;
        } else if (inboxWatchFixture.handle(socket, session, method, args, tag) || inboxCheckFixture.handle(socket, session, method, args, tag) || flagFixture.handle(socket, session, method, args, tag) || corpus?.handle(socket, session, method, args, tag) || accountFixture(socket, session, method, args, tag, mime)) {
          continue;
        } else if (method === 'LIST') {
          socket.write('* LIST (\\HasNoChildren \\Subscribed) "/" "INBOX"\r\n' +
            '* STATUS "INBOX" (MESSAGES 1 RECENT 0 UNSEEN 1)\r\n' +
            '* LIST (\\HasNoChildren) "/" "Archive"\r\n'); ok();
        } else if (method === 'SELECT') {
          if (!/^(?:INBOX|"INBOX")$/i.test(args)) stats.violations.push('unexpected mailbox');
          selected = true;
          socket.write('* FLAGS (\\Seen \\Flagged)\r\n* 1 EXISTS\r\n* 0 RECENT\r\n' +
            '* OK [UIDVALIDITY 77] Valid\r\n* OK [UIDNEXT 43] Next\r\n'); ok();
        } else if (method === 'UID FETCH') {
          session.fetches++;
          if (!selected || !/^42 /.test(args) || !args.includes('BODY.PEEK[]') || args.includes('BODY[]')) {
            stats.violations.push('fetch must use selected mailbox, UID 42 and BODY.PEEK[]'); socket.destroy(); return;
          }
          if (['stall', 'cancel'].includes(session.mode)) continue;
          if (session.mode === 'drop') { socket.destroy(); return; }
          if (session.mode === 'wrongtag') { socket.write('wrongtag OK Completed\r\n'); continue; }
          if (session.mode === 'oversized') { socket.write('* 1 FETCH (UID 42 BODY[] {8388608}\r\n'); continue; }
          // Split a literal across TLS writes to exercise streaming assembly.
          const bytes = Buffer.concat([Buffer.from(`* 1 FETCH (UID 42 FLAGS () INTERNALDATE "13-Sep-2026 10:00:00 +0000" ENVELOPE ${envelope} BODY[] {${mime.length}}\r\n`),
            mime, Buffer.from(`)\r\n${tag} OK Completed\r\n`)]);
          socket.write(bytes.subarray(0, bytes.length - 73));
          setTimeout(() => { if (!socket.destroyed) socket.write(bytes.subarray(bytes.length - 73)); }, 25);
        } else if (method === 'LOGOUT') {
          socket.end(`* BYE Logging out\r\n${tag} OK Completed\r\n`);
        }
      }
    });
  });
  stats.connections[name] = 0;
  server.on('connection', () => stats.connections[name]++);
  server.on('tlsClientError', () => stats.tlsErrors++);
  server.listen(port, '127.0.0.1');
}
