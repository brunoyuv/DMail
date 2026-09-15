// Local TLS fixtures; no mail provider or device-wide certificate installation.
const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const path = require('node:path');
const dir = process.argv[2];
const stats = { plain: 0, trusted: 0, untrusted: 0, wrongHost: 0, cancelled: 0, cancelStarted: 0, tlsErrors: 0 };
const jmap = require('../swift-jmap/fixture.cjs')(stats);
http.createServer((req, res) => {
  if (req.url === '/stats') { res.end(JSON.stringify(stats)); return; }
  if (req.url === '/health') { res.end('ready'); return; }
  if (req.url === '/cancel') {
    stats.cancelStarted++;
    const timer = setTimeout(() => res.end('too late'), 10000);
    res.on('close', () => { if (!res.writableEnded) stats.cancelled++; clearTimeout(timer); });
    return;
  }
  stats.plain++; res.end('NATIVE_HTTP_OK');
}).listen(9660, '127.0.0.1');
for (const [name, port, counter] of [['server',9661,'trusted'], ['untrusted',9662,'untrusted'], ['wrong',9663,'wrongHost']]) {
  const server = https.createServer({ key: fs.readFileSync(path.join(dir, `${name}.key`)), cert: fs.readFileSync(path.join(dir, `${name}.crt`)) }, (req, res) => {
    if (counter === 'trusted' && jmap(req, res)) return;
    stats[counter]++; res.end('NATIVE_TLS_OK');
  });
  server.on('tlsClientError', () => stats.tlsErrors++);
  stats[`${counter}Connections`] = 0;
  server.on('connection', () => stats[`${counter}Connections`]++);
  server.listen(port, '127.0.0.1');
}
