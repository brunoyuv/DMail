const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const moduleValue = { exports: {} };
new Function('require', 'module', 'exports', ts.transpileModule(
  fs.readFileSync('harmony/entry/src/main/ets/data/RdbText.ets', 'utf8'),
  { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText)(name => {
  if (name === '@kit.ArkData') return { relationalStore: {} };
  if (name === '@kit.ArkTS') return { util: { TextDecoder: class {
    constructor(...args) { this.decoder = new TextDecoder(...args); }
    decodeToString(bytes) { return this.decoder.decode(bytes); }
  } } };
  throw new Error('Unexpected RDB text dependency ' + name);
}, moduleValue, moduleValue.exports);
const { readRdbText, rdbTextProjection, RDB_TEXT_INLINE_BYTES } = moduleValue.exports;
const source = "SELECT payload FROM bodies WHERE account = ? AND id = ? AND ready = 1";
function fixture(value) {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec('CREATE TABLE bodies (account TEXT, id TEXT, payload TEXT, ready INTEGER, PRIMARY KEY(account,id))');
  sqlite.prepare('INSERT INTO bodies VALUES (?,?,?,1)').run('a','one',value);
  const state = { queries: 0, chunks: 0, returnedBytes: 0, maxRowBytes: 0, openRows: 0, afterRead: null };
  const db = { querySql: async (sql, args = []) => {
    state.queries++;
    const statement = sqlite.prepare(sql); statement.setReturnArrays(true);
    const rows = statement.all(...args); let index = -1;
    for (const row of rows) {
      const bytes = row.reduce((sum, cell) => sum + (typeof cell === 'string' ? Buffer.byteLength(cell) :
        cell instanceof Uint8Array ? cell.length : 8), 0);
      state.maxRowBytes = Math.max(bytes, state.maxRowBytes);
      if (bytes > 2 * 1024 * 1024) throw new Error('Synthetic RDB ResultSet row exceeds 2 MiB');
    }
    if (sql.includes('substr(CAST(payload AS BLOB)')) state.chunks++;
    state.afterRead?.(sql, state.chunks);
    state.openRows++;
    return { goToFirstRow: () => { index = 0; return rows.length > 0; }, goToNextRow: () => ++index < rows.length,
      getLong: column => rows[index][column], getString: column => rows[index][column],
      getBlob: column => { const value = Uint8Array.from(rows[index][column]); state.returnedBytes += value.length; return value; },
      close: () => state.openRows-- };
  } };
  return { sqlite, db, state, read: (max = 8 * 1024 * 1024, expected) => readRdbText(db, source, ['a','one'], max, expected),
    replace: next => sqlite.prepare('UPDATE bodies SET payload=? WHERE account=? AND id=?').run(next,'a','one') };
}

test('A multi-megabyte Unicode body crosses bounded byte rows intact, including split UTF-8 code points', async () => {
  const value = '\ufeff' + 'A'.repeat(256 * 1024 - 4) + '📬中文é'.repeat(430000) + '\u0000 tail';
  const f = fixture(value);
  try {
    await assert.rejects(f.db.querySql(source, ['a','one']), /2 MiB/);
    f.state.maxRowBytes = 0;
    const result = await f.read();
    assert.equal(result, value); assert.deepEqual(Buffer.from(result), Buffer.from(value));
    assert.ok(f.state.maxRowBytes < 300000); assert.equal(f.state.returnedBytes, Buffer.byteLength(value));
    assert.equal(f.state.chunks, Math.ceil(Buffer.byteLength(value) / (256 * 1024)));
    assert.equal(f.state.openRows, 0);
  } finally { f.sqlite.close(); }
});

test('Large-row projection remains bounded while small values keep their direct string representation', async () => {
  for (const value of ['Small 中文', '文'.repeat(RDB_TEXT_INLINE_BYTES / 3 + 1)]) {
    const f = fixture(value);
    try {
      const rows = await f.db.querySql(`SELECT ${rdbTextProjection('payload')}, length(CAST(payload AS BLOB)) FROM bodies`);
      try { assert.equal(rows.goToFirstRow(), true); assert.equal(rows.getLong(1), Buffer.byteLength(value));
        assert.equal(rows.getString(0), Buffer.byteLength(value) <= RDB_TEXT_INLINE_BYTES ? value : ''); }
      finally { rows.close(); }
    } finally { f.sqlite.close(); }
  }
});

test('Same-size concurrent replacement cannot publish chunks mixed from two complete bodies', async () => {
  const old = 'A'.repeat(700000), replacement = 'B'.repeat(old.length), f = fixture(old);
  try {
    f.state.afterRead = (sql, count) => { if (count === 1 && sql.includes('substr(')) f.replace(replacement); };
    await assert.rejects(f.read(), /Stored text changed/);
    assert.equal(f.state.openRows, 0);
    f.state.afterRead = null; assert.equal(await f.read(), replacement);
  } finally { f.sqlite.close(); }
});

test('Account retirement or deletion during chunk reads rejects the unfinished owned value', async () => {
  for (const remove of [false,true]) {
    const f = fixture('x'.repeat(700000));
    try {
      f.state.afterRead = (sql, count) => { if (count === 1 && sql.includes('substr('))
        f.sqlite.exec(remove ? 'DELETE FROM bodies' : 'UPDATE bodies SET ready=0'); };
      await assert.rejects(f.read(), /Stored text changed/); assert.equal(f.state.openRows, 0);
    } finally { f.sqlite.close(); }
  }
});

test('Character and expected-byte limits reject oversized values without a retry loop', async () => {
  for (const [value,max,expected] of [['a'.repeat(1001),1000,undefined],['文'.repeat(1001),1000,undefined],['abc',100,4]]) {
    const f = fixture(value);
    try { await assert.rejects(f.read(max,expected), /Invalid stored text size/); assert.equal(f.state.chunks,1);
      assert.equal(f.state.openRows,0); }
    finally { f.sqlite.close(); }
  }
});

test('Empty, absent and ambiguous rows remain distinguishable and every cursor closes', async () => {
  const f=fixture('');
  try {
    assert.equal(await f.read(0),'');
    f.sqlite.exec('DELETE FROM bodies'); assert.equal(await f.read(),null);
    await assert.rejects(f.read(8,0), /Stored text changed/);
    f.sqlite.exec("INSERT INTO bodies VALUES ('a','one','first',1),('b','two','second',1)");
    await assert.rejects(readRdbText(f.db,'SELECT payload FROM bodies',[],100), /Ambiguous stored text/);
    assert.equal(f.state.openRows,0);
  } finally { f.sqlite.close(); }
});
