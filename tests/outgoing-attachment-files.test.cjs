const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { pathToFileURL, fileURLToPath } = require('node:url');
const ts = require('../.tools/test/node_modules/typescript');
const week = 7 * 24 * 60 * 60 * 1000;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(t) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'dmail-outgoing-test-'));
  const filesDir = path.join(root, 'files'); await fsp.mkdir(filesDir);
  t.after(async () => { await fsp.rm(root, { recursive: true, force: true }); });
  const state = { reads: 0, writes: 0, opens: 0, fsyncs: 0, closes: 0, renames: 0,
    readLimit: Infinity, writeLimit: Infinity, zeroWrite: false, zeroRead: false,
    writeGate: null, writing: deferred(), readGate: null, reading: deferred(), uuid: null, lists: [] };
  const handles = new Map();
  const stat = value => ({ size: value.size, ino: BigInt(value.ino), mtime: value.mtimeMs / 1000,
    ctime: value.ctimeMs / 1000, isFile: () => value.isFile(), isDirectory: () => value.isDirectory(),
    isSymbolicLink: () => value.isSymbolicLink() });
  const translate = async operation => {
    try { return await operation(); }
    catch (error) { if (error.code === 'ENOENT') error.code = 13900002; throw error; }
  };
  const api = {
    OpenMode: { CREATE: fs.constants.O_CREAT, WRITE_ONLY: fs.constants.O_WRONLY,
      READ_ONLY: fs.constants.O_RDONLY, NOFOLLOW: fs.constants.O_NOFOLLOW },
    async mkdir(name) { await fsp.mkdir(name); },
    async access(name) { return fs.existsSync(name); },
    async lstat(name) { return translate(async () => stat(await fsp.lstat(name))); },
    async stat(name) { return stat(typeof name === 'number' ? await handles.get(name).stat() : await fsp.stat(name)); },
    async open(name, mode) {
      state.opens++; if (name.startsWith('file://')) name = fileURLToPath(name); const handle = await fsp.open(name, mode, 0o600); handles.set(handle.fd, handle); return { fd: handle.fd };
    },
    async read(fd, buffer, options = {}) {
      state.reads++; state.reading.resolve(); if (state.readGate) await state.readGate.promise;
      if (state.zeroRead) return 0;
      const result = await handles.get(fd).read(new Uint8Array(buffer), 0, Math.min(options.length ?? buffer.byteLength, state.readLimit), null);
      return result.bytesRead;
    },
    async write(fd, buffer) {
      state.writes++; state.writing.resolve(); if (state.writeGate) await state.writeGate.promise;
      if (state.zeroWrite) return 0;
      const result = await handles.get(fd).write(new Uint8Array(buffer), 0, Math.min(buffer.byteLength, state.writeLimit), null);
      return result.bytesWritten;
    },
    async fsync(fd) { state.fsyncs++; await handles.get(fd).sync(); },
    async close(file) { state.closes++; const fd = typeof file === 'number' ? file : file.fd; await handles.get(fd).close(); handles.delete(fd); },
    async rename(from, to) { state.renames++; await fsp.rename(from, to); },
    async unlink(name) { await fsp.unlink(name); },
    async listFile(name, options = {}) {
      state.lists.push({ name, ...options });
      const entries = await fsp.readdir(name); return options.listNum ? entries.slice(0, options.listNum) : entries;
    },
    async rmdir(name) { await fsp.rm(name, { recursive: true }); }
  };
  const imports = {
    '@kit.CoreFileKit': { fileIo: api, fileUri: { FileUri: class { constructor(uri) { this.name = path.basename(fileURLToPath(uri)); } } } },
    '@kit.AbilityKit': {}, '@kit.CryptoArchitectureKit': {},
    '../../data/MailCacheModel': {}, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: {
      generateRandomUUID: () => state.uuid || crypto.randomUUID(),
      Base64Helper: class { async encodeToString(bytes) { return Buffer.from(bytes).toString('base64'); } },
      TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } },
      TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
        decodeToString(bytes) { return this.decoder.decode(bytes); } }
    } }
  };
  const load = file => {
    const source = ts.transpileModule(fs.readFileSync(file, 'utf8'),
      { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    const module = { exports: {} };
    new Function('require', 'exports', 'module', source)(name => {
      assert.ok(name in imports, name); return imports[name];
    }, module.exports, module);
    return module.exports;
  };
  imports['../smtp/OutgoingAttachments'] = load('harmony/entry/src/main/ets/mail/smtp/OutgoingAttachments.ts');
  imports['./AttachmentFiles'] = load('harmony/entry/src/main/ets/mail/attachments/AttachmentFiles.ets');
  const model = imports['./OutgoingAttachmentModel'] = load('harmony/entry/src/main/ets/mail/attachments/OutgoingAttachmentModel.ts');
  const exports = load('harmony/entry/src/main/ets/mail/attachments/OutgoingAttachmentFiles.ets');
  const selected = async (name, content) => { const filename = path.join(root, name); await fsp.writeFile(filename, content); return pathToFileURL(filename).href; };
  return { root, filesDir, state, api, exports, model, selected, store: new exports.OutgoingAttachmentFiles(filesDir),
    absolute: ref => path.join(filesDir, 'mail-outgoing', ref), handles };
}

const draft = '12345678-1234-1234-1234-123456789abc', otherDraft = '87654321-1234-1234-1234-123456789abc';
const limit = 10 * 1024 * 1024;

test('An explicitly picked Unicode document is copied once and reopened from persistent storage after its source disappears', async t => {
  const f = await fixture(t), payload = Buffer.alloc(700000, 42), name = '报告 résumé 📄.pdf';
  const uri = await f.selected(name, payload);
  const attachment = await f.store.importURI('account', draft, uri, limit, () => true);
  assert.equal(attachment.name, name); assert.equal(attachment.contentType, 'application/pdf'); assert.equal(attachment.size, payload.length);
  assert.ok(f.model.outgoingAttachmentsOwned('account', draft, [attachment]));
  assert.deepEqual(await fsp.readFile(f.absolute(attachment.file)), payload);
  await fsp.unlink(fileURLToPath(uri));
  const reopened = new f.exports.OutgoingAttachmentFiles(f.filesDir);
  const result = await reopened.read('account', draft, attachment);
  assert.deepEqual(Buffer.from(result.base64, 'base64'), payload);
  const reads = f.state.reads;
  assert.equal(await reopened.path('account', draft, attachment), f.absolute(attachment.file));
  assert.equal(f.state.reads, reads, 'Open/save uses the verified local file without allocating or rereading its bytes');
  assert.equal(f.state.renames, 1); assert.equal(f.state.fsyncs, 1); assert.equal(f.handles.size, 0); assert.equal(f.state.lists.length, 0);
});

test('Draft references bind account, draft and attachment identity and cannot traverse to arbitrary files', async t => {
  const f = await fixture(t), uri = await f.selected('document.txt', 'synthetic');
  const attachment = await f.store.importURI('owner', draft, uri, limit, () => true), opens = f.state.opens;
  for (const [account, draftId, metadata] of [
    ['other', draft, attachment], ['owner', otherDraft, attachment], ['owner', draft, { ...attachment, file: '../' + attachment.file }],
    ['owner', draft, { ...attachment, id: otherDraft }], ['owner', draft, { ...attachment, file: '/' + attachment.file }]
  ]) {
    await assert.rejects(f.store.read(account, draftId, metadata)); await assert.rejects(f.store.path(account, draftId, metadata));
  }
  assert.equal(f.state.opens, opens);
  assert.equal(f.model.outgoingAttachmentsOwned('owner', draft, [{ ...attachment, size: limit + 1 }]), false);
});

test('Short reads and writes complete exactly while zero-progress writes publish no partial attachment', async t => {
  const f = await fixture(t); f.state.readLimit = 19; f.state.writeLimit = 7;
  const payload = 'Synthetic short-write fixture '.repeat(30), uri = await f.selected('fixture.txt', payload);
  const attachment = await f.store.importURI('account', draft, uri, limit, () => true);
  assert.equal(Buffer.from((await f.store.read('account', draft, attachment)).base64, 'base64').toString(), payload);
  f.state.zeroWrite = true; await assert.rejects(f.store.importURI('account', draft, uri, limit, () => true), /imported/);
  assert.equal(f.state.renames, 1); assert.equal(f.handles.size, 0);
  assert.deepEqual(await fsp.readdir(path.dirname(f.absolute(attachment.file))), [path.basename(attachment.file)]);
  f.state.zeroRead = true; await assert.rejects(f.store.read('account', draft, attachment), /Incomplete/);
});

test('The selection budget is enforced before reading and zero-byte files remain valid attachments', async t => {
  const f = await fixture(t), uri = await f.selected('large.pdf', Buffer.alloc(500));
  await assert.rejects(f.store.importURI('account', draft, uri, 499, () => true), /imported/);
  assert.equal(f.state.reads, 0); assert.equal(f.state.writes, 0); assert.equal(f.handles.size, 0);
  const empty = await f.selected('empty.txt', ''), attachment = await f.store.importURI('account', draft, empty, 0, () => true);
  assert.equal(attachment.size, 0); assert.equal((await f.store.read('account', draft, attachment)).base64, '');
  assert.equal(f.handles.size, 0);
});

test('Navigating away during import cancels publication and releases every file handle', async t => {
  const f = await fixture(t), uri = await f.selected('selection.pdf', 'not published');
  let active = true; f.state.writeGate = deferred();
  const importing = f.store.importURI('account', draft, uri, limit, () => active); await f.state.writing.promise;
  active = false; f.state.writeGate.resolve(); await assert.rejects(importing, /imported/);
  assert.equal(f.state.renames, 0); assert.equal(f.handles.size, 0);
  assert.deepEqual(await fsp.readdir(path.join(f.filesDir, 'mail-outgoing', 'account', draft)), []);
});

test('Removing an account cancels active and queued imports across instances and never resurrects its files', async t => {
  const f = await fixture(t), uri = await f.selected('selection.pdf', 'not published'); f.state.writeGate = deferred();
  const one = f.store.importURI('account', draft, uri, limit, () => true); await f.state.writing.promise;
  const reopened = new f.exports.OutgoingAttachmentFiles(f.filesDir), two = reopened.importURI('account', draft, uri, limit, () => true);
  const removing = reopened.forgetAccount('account'); f.state.writeGate.resolve();
  const outcomes = await Promise.allSettled([one, two]); assert.ok(outcomes.every(outcome => outcome.status === 'rejected'));
  await removing; assert.ok(!fs.existsSync(path.join(f.filesDir, 'mail-outgoing', 'account'))); assert.equal(f.handles.size, 0);
  await assert.rejects(reopened.importURI('account', draft, uri, limit, () => true), /canceled/);
  const other = await reopened.importURI('other', draft, uri, limit, () => true);
  assert.equal((await reopened.read('other', draft, other)).size, 13);
});

test('A file changed after attachment selection fails preflight without returning truncated bytes', async t => {
  const f = await fixture(t), uri = await f.selected('selected.bin', 'initial payload');
  const attachment = await f.store.importURI('account', draft, uri, limit, () => true);
  await fsp.appendFile(f.absolute(attachment.file), 'changed');
  await assert.rejects(f.store.read('account', draft, attachment), /unavailable/);
  await assert.rejects(f.store.path('account', draft, attachment), /unavailable/);
  assert.equal(f.handles.size, 0);
});

test('Saved drafts remain readable after seven days; attachment names and metadata never choose physical paths', async t => {
  const f = await fixture(t), uri = await f.selected('résumé.docx', 'persistent draft');
  const attachment = await f.store.importURI('account', draft, uri, limit, () => true);
  assert.equal(attachment.contentType, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
  const old = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000); await fsp.utimes(f.absolute(attachment.file), old, old);
  assert.equal(Buffer.from((await f.store.read('account', draft, attachment)).base64, 'base64').toString(), 'persistent draft');
  const outside = await f.selected('outside.txt', 'untouched');
  await fsp.unlink(f.absolute(attachment.file)); await fsp.symlink(fileURLToPath(outside), f.absolute(attachment.file));
  await assert.rejects(f.store.read('account', draft, attachment), /unavailable/);
  await f.store.forgetAccount('account'); assert.equal(await fsp.readFile(fileURLToPath(outside), 'utf8'), 'untouched');
});

test('Explicitly discarded drafts cancel in-flight imports without removing another draft or account', async t => {
  const f = await fixture(t), uri = await f.selected('selected.pdf', 'survives elsewhere');
  const kept = await f.store.importURI('account', otherDraft, uri, limit, () => true);
  f.state.writeGate = deferred();
  const pending = f.store.importURI('account', draft, uri, limit, () => true); await f.state.writing.promise;
  const removed = f.store.forgetDraft('account', draft); f.state.writeGate.resolve();
  await assert.rejects(pending, /imported|canceled/); await removed;
  assert.ok(!fs.existsSync(path.join(f.filesDir, 'mail-outgoing', 'account', draft)));
  assert.equal((await f.store.read('account', otherDraft, kept)).size, 18);
  await assert.rejects(f.store.importURI('account', draft, uri, limit, () => true), /canceled/);
  await f.store.remove('account', otherDraft, kept);
  assert.ok(!fs.existsSync(f.absolute(kept.file))); assert.equal(f.handles.size, 0);
});

test('A source edited during selection import is never published and a removed account cannot return an open read', async t => {
  const f = await fixture(t), uri = await f.selected('selected.pdf', 'initial payload');
  f.state.writeGate = deferred();
  const pending = f.store.importURI('account', draft, uri, limit, () => true); await f.state.writing.promise;
  await fsp.appendFile(fileURLToPath(uri), 'changed while importing'); f.state.writeGate.resolve();
  await assert.rejects(pending, /imported/); assert.equal(f.state.renames, 0);
  f.state.writeGate = null;
  const attachment = await f.store.importURI('account', draft, uri, limit, () => true);
  f.state.reading = deferred(); f.state.readGate = deferred();
  const reading = f.store.read('account', draft, attachment); await f.state.reading.promise;
  const removing = f.store.forgetAccount('account'); f.state.readGate.resolve();
  await assert.rejects(reading, /canceled/); await removing; assert.equal(f.handles.size, 0);
});

test('Startup cleanup retains old active drafts and fresh Sent owners, preserves new unreferenced files, and removes expired orphans', async t => {
  const f = await fixture(t), uri = await f.selected('cleanup.pdf', 'synthetic');
  const live = await f.store.importURI('account', draft, uri, limit, () => true);
  const sent = await f.store.importURI('account', otherDraft, uri, limit, () => true);
  const expiredId = crypto.randomUUID(), freshId = crypto.randomUUID();
  const expired = await f.store.importURI('account', expiredId, uri, limit, () => true);
  const fresh = await f.store.importURI('account', freshId, uri, limit, () => true);
  const old = new Date(Date.now() - week - 10000);
  for (const attachment of [live, sent, expired]) { await fsp.utimes(f.absolute(attachment.file), old, old); }
  const orphan = f.absolute(expired.file) + '.part'; await fsp.writeFile(orphan, 'unfinished');
  const wrongName = path.join(path.dirname(orphan), 'unrelated.txt'); await fsp.writeFile(wrongName, 'do not remove');
  const outside = await f.selected('outside-prune.bin', 'sentinel');
  const link = path.join(path.dirname(orphan), crypto.randomUUID() + '.bin'); await fsp.symlink(fileURLToPath(outside), link);
  await f.store.prune([`account/${draft}`, `account/${otherDraft.toUpperCase()}`]);
  assert.ok(fs.existsSync(f.absolute(live.file))); assert.ok(fs.existsSync(f.absolute(sent.file)));
  assert.ok(fs.existsSync(f.absolute(fresh.file))); assert.ok(!fs.existsSync(f.absolute(expired.file))); assert.ok(!fs.existsSync(orphan));
  assert.ok(fs.existsSync(wrongName)); assert.ok((await fsp.lstat(link)).isSymbolicLink());
  assert.equal(await fsp.readFile(fileURLToPath(outside), 'utf8'), 'sentinel');
  assert.equal(f.handles.size, 0);
});

test('Startup cleanup has a hard bounded directory-entry budget and invalid ownership input is a no-op', async t => {
  const f = await fixture(t), folder = path.join(f.filesDir, 'mail-outgoing', 'account', draft);
  await fsp.mkdir(folder, { recursive: true }); const old = new Date(Date.now() - week - 10000);
  for (let index = 0; index < 200; index++) {
    const file = path.join(folder, crypto.randomUUID() + '.bin'); await fsp.writeFile(file, 'old'); await fsp.utimes(file, old, old);
  }
  await f.store.prune(['account/invalid-draft']); assert.equal((await fsp.readdir(folder)).length, 200);
  assert.equal(f.state.lists.length, 0);
  await f.store.prune([]);
  const remaining = (await fsp.readdir(folder)).length;
  assert.ok(remaining > 0 && remaining < 200); assert.ok(200 - remaining <= 128);
  assert.ok(f.state.lists.every(entry => entry.listNum > 0 && entry.listNum <= 128 && entry.recursion === false));
});

test('Startup cleanup skips accounts with active imports and never traverses symbolic-link owners', async t => {
  const f = await fixture(t), uri = await f.selected('prune-active.pdf', 'keep importing');
  const oldFile = await f.store.importURI('account', otherDraft, uri, limit, () => true);
  const old = new Date(Date.now() - week - 10000); await fsp.utimes(f.absolute(oldFile.file), old, old);
  f.state.writing = deferred(); f.state.writeGate = deferred();
  const pending = f.store.importURI('account', draft, uri, limit, () => true); await f.state.writing.promise;
  const external = path.join(f.root, 'external'); await fsp.mkdir(external);
  await fsp.symlink(external, path.join(f.filesDir, 'mail-outgoing', 'linked'));
  await f.store.prune([]);
  assert.ok(fs.existsSync(f.absolute(oldFile.file)), 'The entire active account must stay out of startup cleanup');
  assert.ok(!f.state.lists.some(entry => entry.name === external || entry.name.endsWith('/linked')));
  f.state.writeGate.resolve(); const imported = await pending;
  assert.equal(await f.store.path('account', draft, imported), f.absolute(imported.file)); assert.equal(f.handles.size, 0);
});
