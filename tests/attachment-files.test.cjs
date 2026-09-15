const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const ts = require('../.tools/test/node_modules/typescript');
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const week = 7 * 24 * 60 * 60 * 1000;
function fixture() {
  const now = Date.now(), files = new Map(), descriptors = new Map();
  const state = { lists: 0, writes: 0, renames: 0, downloads: 0, closes: 0, writeLimit: Infinity, gate: null, writing: deferred(), unlinkGate: null, unlinking: deferred(), savedNames: [], copies: [] };
  const directory = path => files.set(path, { directory: true, mtime: now / 1000 });
  const entry = path => { if (!files.has(path)) throw new Error('ENOENT'); return files.get(path); };
  directory('/cache'); directory('/cache/mail-attachments'); directory('/files'); directory('/files/mail-attachments');
  let nextFd = 1;
  const api = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    async access(path) { return files.has(path); },
    async stat(path) { const row = entry(path); return { mtime: row.mtime, size: row.bytes?.length ?? 0, isDirectory: () => !!row.directory, isFile: () => !row.directory }; },
    async listFile(path) { state.lists++; entry(path); return [...files.keys()].filter(key => key.startsWith(path + '/') && !key.slice(path.length + 1).includes('/')).map(key => key.slice(path.length + 1)); },
    async mkdir(path) { directory(path); },
    async open(path) { files.set(path, { bytes: Buffer.alloc(0), mtime: now / 1000 }); const file = { fd: nextFd++ }; descriptors.set(file.fd, path); return file; },
    async write(fd, buffer) {
      state.writes++; state.writing.resolve(); if (state.gate) await state.gate.promise;
      const row = entry(descriptors.get(fd)); const source = Buffer.from(buffer);
      const count = Math.min(source.length, state.writeLimit); row.bytes = Buffer.concat([row.bytes, source.subarray(0, count)]); return count;
    },
    async close(file) { state.closes++; descriptors.delete(typeof file === 'number' ? file : file.fd); },
    async copyFile(from, fd) { state.copies.push(from); entry(descriptors.get(fd)).bytes = Buffer.from(entry(from).bytes); },
    async rename(from, to) { state.renames++; files.set(to, entry(from)); files.delete(from); },
    async unlink(path) { state.unlinking.resolve(); if (state.unlinkGate) await state.unlinkGate.promise; files.delete(path); },
    accessSync(path) { return files.has(path); },
    rmdirSync(path) { for (const key of files.keys()) if (key === path || key.startsWith(path + '/')) files.delete(key); }
  };
  for (const name of ['statSync', 'listFileSync', 'mkdirSync', 'openSync', 'writeSync', 'closeSync', 'renameSync', 'unlinkSync', 'copyFileSync']) {
    api[name] = () => { throw new Error('Blocking filesystem API: ' + name); };
  }
  const imports = {
    '@kit.AbilityKit': { wantConstant: { Flags: { FLAG_AUTH_READ_URI_PERMISSION: 1 } } },
    '@kit.CoreFileKit': { fileIo: api, fileUri: { getUriFromPath: path => 'file://' + encodeURI(path) },
      picker: { DocumentViewPicker: class { async save(options) { state.savedNames.push(options.newFileNames); return ['/picked.pdf']; } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256'); return { update: async ({ data }) => hash.update(data), digest: async () => ({ data: hash.digest() }) };
    } } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } }, Base64Helper: class { async decode(value) { return Buffer.from(value, 'base64'); } } } },
    '../../data/MailCacheModel': { cacheIsFresh: stamp => now - stamp < week }
  };
  const source = ts.transpileModule(fs.readFileSync('harmony/entry/src/main/ets/mail/attachments/AttachmentFiles.ets', 'utf8'),
    { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('require', 'exports', 'module', source)(name => { assert.ok(name in imports, name); return imports[name]; }, module.exports, module);
  const AttachmentFiles = module.exports.AttachmentFiles;
  const attachment = { id: '2', name: 'Synthetic.pdf' };
  const download = async () => { state.downloads++; return { base64: Buffer.from('Synthetic attachment payload').toString('base64') }; };
  const load = (fetch = download) => AttachmentFiles.load({ filesDir: '/files', cacheDir: '/cache' }, 'account', 'message', attachment, fetch);
  return { AttachmentFiles, state, files, now, load, download, directory };
}

test('Simultaneous attachment requests share one asynchronous download and a fresh cache hit does not scan folders', async () => {
  const f = fixture(), gate = deferred(), started = deferred();
  const download = async () => { started.resolve(); await gate.promise; return f.download(); };
  const first = f.load(download), second = f.load(download); await started.promise; gate.resolve();
  const [a, b] = await Promise.all([first, second]); assert.equal(a, b);
  assert.equal(f.state.downloads, 1); assert.equal(f.state.writes, 1); assert.equal(f.state.renames, 1);
  assert.equal(f.files.get(a).bytes.toString(), 'Synthetic attachment payload');
  assert.equal(await f.load(() => { throw new Error('Unexpected download'); }), a);
  assert.equal(f.state.lists, 0); assert.equal(f.state.writes, 1);
});

test('Short asynchronous writes finish all bytes before a file is renamed', async () => {
  const f = fixture(); f.state.writeLimit = 7; const path = await f.load();
  assert.ok(f.state.writes > 1); assert.equal(f.state.renames, 1); assert.equal(f.state.closes, 1);
  assert.equal(f.files.get(path).bytes.toString(), 'Synthetic attachment payload');
  assert.ok(!f.files.has(path + '.part'));
});

test('A zero-byte write cannot replace a previous cached attachment with a truncated file', async () => {
  const f = fixture(); const path = await f.load(); const old = f.files.get(path); old.mtime = (f.now - week - 1) / 1000;
  f.state.writeLimit = 0; await assert.rejects(f.load(), /could not be written/);
  assert.equal(f.files.get(path), old); assert.equal(f.state.renames, 1); assert.equal(f.state.closes, 2);
  assert.ok(!f.files.has(path + '.part'));
});

test('Cleanup removes expired/orphaned files but does not delete an attachment currently being written', async () => {
  const f = fixture(); f.state.gate = deferred(); const pending = f.load(); await f.state.writing.promise;
  const folder = '/files/mail-attachments/account';
  f.files.set(folder + '/expired', { bytes: Buffer.from('old'), mtime: (f.now - week - 1) / 1000 });
  f.files.set(folder + '/orphan.part', { bytes: Buffer.from('partial'), mtime: f.now / 1000 });
  f.files.set(folder + '/fresh', { bytes: Buffer.from('fresh'), mtime: f.now / 1000 });
  await f.AttachmentFiles.prune('/files');
  assert.ok(!f.files.has(folder + '/expired')); assert.ok(!f.files.has(folder + '/orphan.part')); assert.ok(f.files.has(folder + '/fresh'));
  assert.equal([...f.files.keys()].filter(key => key.endsWith('.part')).length, 1);
  f.state.gate.resolve(); const path = await pending; assert.equal(f.files.get(path).bytes.toString(), 'Synthetic attachment payload');
});

test('Removing an account while its download is pending prevents a late attachment from recreating private files', async () => {
  const f = fixture(), gate = deferred(), started = deferred();
  const pending = f.load(async () => { started.resolve(); await gate.promise; return f.download(); });
  await started.promise; f.AttachmentFiles.forgetAccount('/files', 'account'); gate.resolve();
  await assert.rejects(pending, /account was removed/);
  assert.equal(f.state.writes, 0); assert.equal(f.state.renames, 0);
  assert.ok(![...f.files.keys()].some(path => path.startsWith('/files/mail-attachments/account/')));
});

test('A new attachment waits for an already queued orphan unlink before creating its temporary file', async () => {
  const f = fixture(), folder = '/files/mail-attachments/account'; f.directory(folder);
  const key = crypto.createHash('sha256').update('message\n2').digest('hex');
  const path = `${folder}/${key}-Synthetic.pdf`;
  f.files.set(path + '.part', { bytes: Buffer.from('orphan'), mtime: f.now / 1000 });
  f.state.unlinkGate = deferred(); const pruning = f.AttachmentFiles.prune('/files'); await f.state.unlinking.promise;
  const loading = f.load(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.state.downloads, 0); assert.equal(f.state.writes, 0, 'An in-flight unlink must finish before replacing its path');
  f.state.unlinkGate.resolve(); await pruning; assert.equal(await loading, path);
  assert.equal(f.files.get(path).bytes.toString(), 'Synthetic attachment payload');
  assert.equal(f.state.downloads, 1); assert.equal(f.state.renames, 1); assert.ok(!f.files.has(path + '.part'));
});

test('A failed shared download releases its ownership so an explicit retry can succeed', async () => {
  const f = fixture(), gate = deferred(), started = deferred(); let attempts = 0;
  const failed = async () => { attempts++; started.resolve(); await gate.promise; throw new Error('Synthetic offline'); };
  const one = f.load(failed), two = f.load(failed); await started.promise; gate.resolve();
  const results = await Promise.allSettled([one, two]); assert.ok(results.every(result => result.status === 'rejected'));
  assert.equal(attempts, 1); const path = await f.load(); assert.ok(f.files.has(path)); assert.equal(f.state.downloads, 1);
});

test('Decoded Unicode PDF names survive cache, Open URI, and Save picker without another download', async () => {
  const f = fixture(), wants = [];
  const context = { filesDir: '/files', cacheDir: '/cache', startAbility: async want => wants.push(want) };
  const name = '报告 résumé 📄.pdf', attachment = { id: '2', name };
  const path = await f.AttachmentFiles.load(context, 'account', 'message', attachment, f.download);
  assert.ok(path.endsWith('-' + name));
  await f.AttachmentFiles.open(context, path, 'application/pdf');
  assert.equal(decodeURI(wants[0].uri), 'file://' + path); assert.equal(wants[0].type, 'application/pdf');
  await f.AttachmentFiles.save(context, path, name);
  assert.deepEqual(f.state.savedNames, [[name]]); assert.deepEqual(f.state.copies, [path]);
  assert.equal(f.files.get('/picked.pdf').bytes.toString(), 'Synthetic attachment payload');
  assert.equal(await f.AttachmentFiles.load(context, 'account', 'message', attachment, f.download), path);
  assert.equal(f.state.downloads, 1);
});

test('Long Unicode filenames preserve the PDF suffix and stay within cache filename byte limits', async () => {
  const f = fixture();
  for (const name of ['报'.repeat(100) + '.pdf', 'x'.repeat(99) + '📄.pdf', '📄'.repeat(60) + '.pdf']) {
    const attachment = { id: name, name };
    const path = await f.AttachmentFiles.load({ filesDir: '/files', cacheDir: '/cache' }, 'account', 'message', attachment, f.download);
    const basename = path.split('/').at(-1);
    assert.ok(basename.endsWith('.pdf')); assert.ok(Buffer.byteLength(basename + '.part', 'utf8') <= 255);
    assert.ok(!/[\ud800-\udfff]/u.test(basename), 'No isolated UTF-16 surrogate may reach filesystem APIs');
    assert.ok(!basename.includes('\ufffd'));
  }
  assert.equal(f.AttachmentFiles.filename('../报告/\u0000.pdf'), '_报告__.pdf');
  assert.equal(f.AttachmentFiles.filename('Synthetic.pdf'), 'Synthetic.pdf');
});

test('Legacy cached files migrate into persistent storage with their original retention and no download', async () => {
  const f = fixture(), key = crypto.createHash('sha256').update('message\n2').digest('hex');
  const legacyFolder = '/cache/mail-attachments/account'; f.directory(legacyFolder);
  const legacy = `${legacyFolder}/${key}-Synthetic.pdf`;
  const row = { bytes: Buffer.from('Saved before upgrade'), mtime: (f.now - week + 5000) / 1000 };
  f.files.set(legacy, row);
  const path = await f.load(() => { throw new Error('Must remain available offline'); });
  assert.equal(path, `/files/mail-attachments/account/${key}-Synthetic.pdf`);
  assert.equal(f.files.get(path), row); assert.equal(f.files.get(path).mtime, row.mtime);
  assert.ok(!f.files.has(legacy)); assert.equal(f.state.downloads, 0); assert.equal(f.state.writes, 0);
  assert.equal(f.state.renames, 1);
  // Reading again does not touch mtime, preserving the original seven-day expiry.
  await f.load(() => { throw new Error('Must remain available offline'); });
  assert.equal(f.files.get(path).mtime, (f.now - week + 5000) / 1000);
});

test('An expired legacy file does not gain another seven days by migrating', async () => {
  const f = fixture(), key = crypto.createHash('sha256').update('message\n2').digest('hex');
  const folder = '/cache/mail-attachments/account'; f.directory(folder);
  const legacy = `${folder}/${key}-Synthetic.pdf`;
  const old = { bytes: Buffer.from('Expired'), mtime: (f.now - week - 1) / 1000 }; f.files.set(legacy, old);
  await assert.rejects(f.load(() => { throw new Error('Offline'); }), /Offline/);
  assert.equal(f.files.get(legacy), old); assert.equal(f.state.renames, 0);
  const path = await f.load(); assert.equal(f.files.get(path).bytes.toString(), 'Synthetic attachment payload');
  assert.equal(f.state.downloads, 1);
});

test('A removed account rejects future stale callbacks while another account keeps its own attachment', async () => {
  const f = fixture(); const path = await f.load();
  f.AttachmentFiles.forgetAccount('/files', 'account');
  await assert.rejects(f.load(), /account was removed/);
  assert.ok(!f.files.has(path)); assert.equal(f.state.downloads, 1);
  const other = await f.AttachmentFiles.load({ filesDir: '/files', cacheDir: '/cache' }, 'other', 'message',
    { id: '2', name: 'Synthetic.pdf' }, f.download);
  assert.ok(other.startsWith('/files/mail-attachments/other/')); assert.equal(f.state.downloads, 2);
});

test('Fresh directories or oversized files cannot masquerade as a saved attachment', async () => {
  const f = fixture(); const path = await f.load();
  f.files.get(path).directory = true;
  await f.load(); assert.equal(f.state.downloads, 2);
  f.files.get(path).bytes = Buffer.alloc(f.AttachmentFiles.limit + 1);
  await f.load(); assert.equal(f.state.downloads, 3);
  assert.equal(f.files.get(path).bytes.toString(), 'Synthetic attachment payload');
});
