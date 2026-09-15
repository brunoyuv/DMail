const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const ts = require('../.tools/test/node_modules/typescript');
const week = 7 * 24 * 60 * 60 * 1000;
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

async function fixture(t) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), 'dmail-content-test-'));
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
    async lstat(name) { return translate(async () => stat(await fsp.lstat(name))); },
    async stat(name) { return stat(typeof name === 'number' ? await handles.get(name).stat() : await fsp.stat(name)); },
    async open(name, mode) {
      state.opens++; const handle = await fsp.open(name, mode, 0o600); handles.set(handle.fd, handle); return { fd: handle.fd };
    },
    async read(fd, buffer, options) {
      state.reads++; state.reading.resolve(); if (state.readGate) await state.readGate.promise;
      if (state.zeroRead) return 0;
      const result = await handles.get(fd).read(new Uint8Array(buffer), 0, Math.min(options.length, state.readLimit), null);
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
    async rmdir(name) { await fsp.rmdir(name); }
  };
  const imports = {
    '@kit.CoreFileKit': { fileIo: api }, '@kit.BasicServicesKit': {},
    '@kit.ArkTS': { util: {
      generateRandomUUID: () => state.uuid || crypto.randomUUID(),
      // Native MatePad encodeInto('') returns undefined, unlike Node's encoder.
      TextEncoder: class { encodeInto(value) { return value === '' ? undefined : new TextEncoder().encode(value); } },
      TextDecoder: class { constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
        decodeToString(bytes) { assert.ok(bytes.length > 0, 'Empty files do not need the native decoder'); return this.decoder.decode(bytes); } }
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
  imports['./MailContentFileModel'] = load('harmony/entry/src/main/ets/data/MailContentFileModel.ts');
  const exports = load('harmony/entry/src/main/ets/data/MailContentFiles.ets');
  return { root, filesDir, state, api, exports, store: new exports.MailContentFiles(filesDir),
    absolute: ref => path.join(filesDir, 'mail-content', ref), handles };
}

test('Persisted private UTF-8 files preserve large HTML, BOM, combining characters, emoji and empty text across store reopen', async t => {
  const f = await fixture(t);
  const html = '\ufeff<html><body>' + '跨行🙂e\u0301\n'.repeat(330000) + '</body></html>';
  const ref = await f.store.write('account-a', 'html', html);
  assert.ok(f.exports.mailContentReferenceValid('account-a', ref, 'html'));
  assert.equal(await fsp.readFile(f.absolute(ref), 'utf8'), html, 'Content is actual readable UTF-8, not encoded DB JSON');
  const reopened = new f.exports.MailContentFiles(f.filesDir);
  assert.equal(await reopened.read('account-a', ref, html.length), html);
  const empty = await reopened.write('account-a', 'text', '');
  assert.equal(await reopened.read('account-a', empty, 0), '');
  assert.equal(f.state.fsyncs, 2); assert.equal(f.state.renames, 2);
  assert.ok(f.state.reads > 1); assert.equal(f.handles.size, 0);
  assert.ok(!(await fsp.readdir(path.dirname(f.absolute(ref)))).some(name => name.endsWith('.part')));
});

test('Strict reference/account binding blocks traversal, wrong extensions and another account without opening a file', async t => {
  const f = await fixture(t), ref = await f.store.write('first', 'text', 'saved');
  const opens = f.state.opens;
  for (const value of [ref, '../' + ref, '/' + ref, ref.replace('.txt', '.part'), ref.replace('/', '/./'), 'first/%2e%2e.html']) {
    await assert.rejects(f.store.read('other', value, 100));
  }
  for (const account of ['', '.', '..', 'a/b', 'a\\b', 'a\u0000b', 'a'.repeat(129)]) {
    await assert.rejects(f.store.write(account, 'text', 'no'));
  }
  assert.equal(f.state.opens, opens);
  assert.equal(f.exports.mailContentReferenceValid('first', ref, 'html'), false);
  await assert.rejects(f.store.read('first', ref, 2), /unavailable|limit/);
});

test('Short file reads and writes are completed; zero-progress failure never publishes a partial reference', async t => {
  const f = await fixture(t); f.state.writeLimit = 7; f.state.readLimit = 5;
  const text = '标题🙂尾声'.repeat(100), ref = await f.store.write('account', 'text', text);
  assert.equal(await f.store.read('account', ref, text.length), text);
  f.state.zeroWrite = true;
  await assert.rejects(f.store.write('account', 'text', 'truncated'), /could not be saved/);
  assert.equal(f.state.renames, 1);
  assert.equal((await fsp.readdir(path.dirname(f.absolute(ref)))).length, 1);
  f.state.zeroRead = true; await assert.rejects(f.store.read('account', ref, text.length), /Incomplete/);
  assert.equal(f.handles.size, 0);
});

test('Invalid UTF-8, invalid surrogates, byte limits and caller character limits fail without replacement text', async t => {
  const f = await fixture(t);
  const ref = await f.store.write('account', 'text', 'valid');
  await fsp.writeFile(f.absolute(ref), Buffer.from([0xff]));
  await assert.rejects(f.store.read('account', ref, 100));
  await assert.rejects(f.store.write('account', 'text', '\ud800'), /Unicode/);
  await assert.rejects(f.store.write('account', 'text', '界'.repeat(12 * 1024 * 1024)), /limit/);
  const valid = await f.store.write('account', 'text', '🙂abc');
  await assert.rejects(f.store.read('account', valid, 4), /limit/);
  const oversized = await fsp.open(f.absolute(ref), 'w'); await oversized.truncate(32 * 1024 * 1024 + 1); await oversized.close();
  await assert.rejects(f.store.read('account', ref, 32 * 1024 * 1024), /unavailable/);
});

test('Existing final names and symbolic links are not overwritten or followed', async t => {
  const f = await fixture(t);
  f.state.uuid = '01234567-89ab-cdef-0123-456789abcdef';
  const ref = await f.store.write('account', 'text', 'first');
  await assert.rejects(f.store.write('account', 'text', 'replacement'), /could not be saved/);
  assert.equal(await fsp.readFile(f.absolute(ref), 'utf8'), 'first');
  const outside = path.join(f.root, 'outside.txt'); await fsp.writeFile(outside, 'private sentinel');
  await fsp.unlink(f.absolute(ref)); await fsp.symlink(outside, f.absolute(ref));
  const opens = f.state.opens;
  await assert.rejects(f.store.read('account', ref, 100), /Invalid/);
  assert.equal(f.state.opens, opens);
  await fsp.mkdir(path.join(f.root, 'outside-folder'));
  await fsp.symlink(path.join(f.root, 'outside-folder'), path.join(f.filesDir, 'mail-content', 'linked'));
  await assert.rejects(f.store.write('linked', 'html', '<p>no</p>'), /could not be saved/);
  await f.store.forgetAccount('account');
  assert.equal(await fsp.readFile(outside, 'utf8'), 'private sentinel');
});

test('An account removal cancels in-flight and queued writes across store instances and prevents resurrection', async t => {
  const f = await fixture(t); f.state.writeGate = deferred();
  const pending = f.store.write('account', 'text', 'unfinished');
  await f.state.writing.promise;
  const other = new f.exports.MailContentFiles(f.filesDir);
  const queued = other.write('account', 'html', '<p>queued</p>');
  const removed = other.forgetAccount('account');
  f.state.writeGate.resolve();
  const results = await Promise.allSettled([pending, queued]);
  assert.ok(results.every(value => value.status === 'rejected'));
  await removed;
  await assert.rejects(f.store.write('account', 'text', 'late'), /removed/);
  assert.equal(fs.existsSync(path.join(f.filesDir, 'mail-content', 'account')), false);
  assert.equal(f.handles.size, 0);
  assert.equal(await f.store.read('other', await other.write('other', 'text', 'kept'), 4), 'kept');
});

test('Account removal invalidates an already-open read before returning content', async t => {
  const f = await fixture(t), ref = await f.store.write('account', 'text', 'sensitive synthetic content');
  f.state.readGate = deferred();
  const reading = f.store.read('account', ref, 100); await f.state.reading.promise;
  const removed = f.store.forgetAccount('account'); f.state.readGate.resolve();
  await assert.rejects(reading, /removed/); await removed;
  assert.equal(f.handles.size, 0);
});

test('Prune removes only expired complete files and old temp files, preserves active/fresh files, and never follows links', async t => {
  const f = await fixture(t);
  const old = await f.store.write('account', 'text', 'old');
  const fresh = await f.store.write('account', 'text', 'fresh');
  const folder = path.dirname(f.absolute(old));
  const oldTemp = path.join(folder, '11111111-1111-1111-1111-111111111111.html.part');
  const newTemp = path.join(folder, '22222222-2222-2222-2222-222222222222.txt.part');
  await fsp.writeFile(oldTemp, 'partial'); await fsp.writeFile(newTemp, 'still writing elsewhere');
  const previous = new Date(Date.now() - week - 2000);
  await fsp.utimes(f.absolute(old), previous, previous); await fsp.utimes(oldTemp, previous, previous);
  await assert.rejects(f.store.read('account', old, 100), /unavailable/);
  const outside = path.join(f.root, 'outside.txt'); await fsp.writeFile(outside, 'sentinel');
  const link = path.join(folder, '33333333-3333-3333-3333-333333333333.html'); await fsp.symlink(outside, link);
  await f.store.prune();
  assert.equal(fs.existsSync(f.absolute(old)), false); assert.equal(fs.existsSync(oldTemp), false);
  assert.equal(await f.store.read('account', fresh, 100), 'fresh');
  assert.equal(fs.existsSync(newTemp), true); assert.equal((await fsp.lstat(link)).isSymbolicLink(), true);
  assert.ok(f.state.lists.every(call => call.listNum > 0 && call.recursion === false));
  f.state.writeGate = deferred(); const writing = f.store.write('busy', 'html', 'active'); await f.state.writing.promise;
  const before = f.state.lists.length; await f.store.prune();
  assert.ok(!f.state.lists.slice(before).some(call => call.name.endsWith('/busy')));
  f.state.writeGate.resolve(); await writing;
});

test('Zero-byte text and HTML stay complete across reopen while owner, missing-file and retention checks still apply', async t => {
  const f = await fixture(t);
  for (const kind of ['text', 'html']) {
    const reference = await f.store.write('empty-account', kind, '');
    assert.equal((await fsp.stat(f.absolute(reference))).size, 0);
    const reopened = new f.exports.MailContentFiles(f.filesDir);
    assert.equal(await reopened.read('empty-account', reference, 0), '');
    await assert.rejects(reopened.read('other-account', reference, 0));
    const previous = new Date(Date.now() - week - 2000);
    await fsp.utimes(f.absolute(reference), previous, previous);
    await assert.rejects(reopened.read('empty-account', reference, 0), /unavailable/);
    await fsp.unlink(f.absolute(reference));
    await assert.rejects(reopened.read('empty-account', reference, 0));
  }
  assert.equal(f.state.writes, 0); assert.equal(f.state.reads, 0);
  assert.equal(f.state.fsyncs, 2); assert.equal(f.state.renames, 2);
  assert.equal(f.handles.size, 0);
});
