const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const clone = value => JSON.parse(JSON.stringify(value));

function fixture(options = {}) {
  const directory = options.committedReads ? fs.mkdtempSync(path.join(os.tmpdir(), 'thunderbird-lease-synthetic-')) : null;
  const filename = directory ? path.join(directory, 'fixture.db') : ':memory:';
  const sqlite = new DatabaseSync(filename);
  if (options.committedReads) sqlite.exec('PRAGMA journal_mode=WAL');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, server_id TEXT, name TEXT, session_url TEXT, status TEXT, email_address TEXT, authentication TEXT, username TEXT); CREATE TABLE oauth_credentials (account_id TEXT PRIMARY KEY, envelope TEXT NOT NULL); CREATE TABLE oauth_refresh_lease (account_id TEXT PRIMARY KEY, owner TEXT NOT NULL, expires INTEGER NOT NULL)");
  const reader = options.committedReads ? new DatabaseSync(filename, { readOnly: true }) : sqlite;
  const counts = { cache: 0, pictures: 0, closed: 0, keysCleared: 0, assetQueries: 0, outgoingFiles: 0 };
  const db = { version: 5,
    executeSql: async (sql, args = []) => { sqlite.prepare(sql).run(...args); },
    querySql: async (sql, args = []) => {
      const statement = reader.prepare(sql), names = statement.columns().map(column => column.name);
      statement.setReturnArrays(true); const rows = statement.all(...args); let index = -1;
      return { goToFirstRow: () => { index = 0; return rows.length > 0; }, goToNextRow: () => ++index < rows.length,
        getColumnIndex: name => names.indexOf(name), getString: column => rows[index][column], getLong: column => rows[index][column], close() {} };
    },
    beginTransaction: () => sqlite.exec('BEGIN'), commit: () => sqlite.exec('COMMIT'), rollBack: () => sqlite.exec('ROLLBACK'),
    close: () => { counts.closed++; }
  };
  const tags = { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, SYNC_TYPE: 5, CONFLICT_RESOLUTION: 6 };
  const secrets = new Map(), accessibility = { DEVICE_UNLOCKED: 2, DEVICE_FIRST_UNLOCKED: 1 };
  const state = { locked: false, now: Date.now(), waits: 0, waitMs: 0 };
  const FixtureDate = options.fastTime ? class extends Date { static now() { return state.now; } } : Date;
  const fixtureTimer = options.fastTime ? (done, delay) => {
    state.waits++; state.waitMs += delay; state.now += delay;
    options.onWait?.(state); queueMicrotask(done); return 0;
  } : setTimeout;
  const asset = { Tag: tags, Accessibility: accessibility, SyncType: { NEVER: 0 }, ReturnType: { ALL: 0 },
    ConflictResolution: { OVERWRITE: 0 }, ErrorCode: { NOT_FOUND: 24000002 },
    query: async query => {
      counts.assetQueries++;
      const alias = Buffer.from(query.get(tags.ALIAS)).toString(), stored = secrets.get(alias);
      if (!stored) throw { code: 24000002 };
      if (state.locked && stored.get(tags.ACCESSIBILITY) === accessibility.DEVICE_UNLOCKED) throw { code: 24000005 };
      return [new Map([...stored].map(([key, value]) => [key, value instanceof Uint8Array ? new Uint8Array(value) : value]))];
    },
    add: async attributes => {
      const alias = Buffer.from(attributes.get(tags.ALIAS)).toString();
      if (secrets.has(alias) && attributes.get(tags.CONFLICT_RESOLUTION) !== 0) throw { code: 24000003 };
      secrets.set(alias, new Map([...attributes].map(([key, value]) => [key, value instanceof Uint8Array ? new Uint8Array(value) : value])));
    },
    remove: async query => { const alias = Buffer.from(query.get(tags.ALIAS)).toString(); if (!secrets.delete(alias)) throw { code: 24000002 }; }
  };
  class Base64Helper { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } decodeSync(text) { return new Uint8Array(Buffer.from(text, 'base64')); } }
  class Encoder { encodeInto(value) { return new TextEncoder().encode(value); } }
  class Decoder { constructor(label, options) { this.decoder = new TextDecoder(label, options); } decodeToString(bytes) { return this.decoder.decode(bytes); } }
  const util = { TextEncoder: Encoder, TextDecoder: Decoder, Base64Helper, generateRandomUUID: () => crypto.randomUUID() };
  function key(bytes) { return { bytes: Buffer.from(bytes), getEncoded() { return { data: new Uint8Array(this.bytes) }; }, clearMem() { this.bytes.fill(0); counts.keysCleared++; } }; }
  const cryptoFramework = { CryptoMode: { ENCRYPT_MODE: 1, DECRYPT_MODE: 2 },
    createSymKeyGenerator: () => ({ generateSymKey: async () => key(crypto.randomBytes(32)), convertKey: async value => key(value.data) }),
    createRandom: () => ({ generateRandom: async length => ({ data: new Uint8Array(crypto.randomBytes(length)) }) }),
    createCipher: () => { let mode, heldKey, params; return {
      init: async (value, k, p) => { mode = value; heldKey = k; params = p; },
      doFinal: async value => {
        if (mode === 1) { const cipher = crypto.createCipheriv('aes-256-gcm', heldKey.bytes, params.iv.data); cipher.setAAD(Buffer.from(params.aad.data));
          return { data: new Uint8Array(Buffer.concat([cipher.update(value.data), cipher.final(), cipher.getAuthTag()])) }; }
        const decipher = crypto.createDecipheriv('aes-256-gcm', heldKey.bytes, params.iv.data);
        decipher.setAAD(Buffer.from(params.aad.data)); decipher.setAuthTag(Buffer.from(params.authTag.data));
        return { data: new Uint8Array(Buffer.concat([decipher.update(value.data), decipher.final()])) };
      }
    }; }
  };
  class JmapError extends Error { constructor(code) { super(code); this.code = code; } }
  const modules = new Map();
  function load(file) {
    file = path.resolve(file); if (modules.has(file)) return modules.get(file);
    const source = fs.readFileSync(file, 'utf8');
    const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    const module = { exports: {} }; modules.set(file, module.exports);
    new Function('require', 'module', 'exports', 'setTimeout', 'Date', code)(name => {
      if (name === '@kit.ArkData') return { relationalStore: { getRdbStore: async () => db, SecurityLevel: { S3: 3 } } };
      if (name === '@kit.AssetStoreKit') return { asset };
      if (name === '@kit.ArkTS') return { util };
      if (name === '@kit.CryptoArchitectureKit') return { cryptoFramework };
      if (name === 'libthunderbird.so') return { validateEmailAddress: () => true };
      if (name.endsWith('/JmapClient')) return { JmapError };
      if (name === './MailContentFiles') return { MailContentFiles: class { async prune() {} async forgetAccount() {} } };
      if (name === './MailCache') return { MailCache: class { static async initialize() { counts.cache++; } } };
      if (name === './PictureCache') return { PictureCache: class { static async initialize() { counts.pictures++; } } };
      if (name.endsWith('/AttachmentFiles')) return { AttachmentFiles: { forgetAccount() {} } };
      // Credential/notification fixtures never touch user-selected documents.
      // The real outgoing helper has its own filesystem and retention tests.
      if (name.endsWith('/OutgoingAttachmentFiles')) return { OutgoingAttachmentFiles: class {
        constructor() { counts.outgoingFiles++; }
        async prune() {} async forgetAccount() {} async forgetDraft() {}
      } };
      if (name.endsWith('/NativeSmtpClient')) return { SmtpSettings: class {} };
      if (name.endsWith('/NativeBrowserOAuth')) return { NativeBrowserOAuth: class {} };
      if (name.endsWith('/RegisteredMailOAuth')) return { RegisteredMailOAuth: {
        valid: login => login?.registration?.provider === 'synthetic' && typeof login.tokens?.expiresAt === 'number',
        incoming: () => 'imaps://example.test:993', outgoing: () => 'smtp://example.test:587',
        allowsOutgoing: (_provider, endpoint) => endpoint === 'smtp://example.test:587'
      } };
      if (!name.startsWith('.')) throw new Error(`Unexpected import ${name}`);
      const base = path.resolve(path.dirname(file), name); return load(fs.existsSync(`${base}.ts`) ? `${base}.ts` : `${base}.ets`);
    }, module, module.exports, fixtureTimer, FixtureDate);
    return module.exports;
  }
  const { AccountStore } = load('harmony/entry/src/main/ets/data/AccountStore.ets');
  const { OAuthSecretBox } = load('harmony/entry/src/main/ets/data/OAuthSecretBox.ets');
  const { NotificationStore } = load('harmony/entry/src/main/ets/data/NotificationStore.ets');
  const store = () => { const value = new AccountStore('notification_test.db'); value.db = db; value.notificationData = new NotificationStore(db, task => value.enqueue(task)); return value; };
  const account = (id, oauth = false) => {
    const value = { id, serverId: 'default', name: id, emailAddress: `${id}@example.test`, sessionUrl: 'imaps://example.test:993', authentication: oauth ? 'oauth' : '', username: oauth ? `${id}@example.test` : '' };
    sqlite.prepare('INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(id, 'default', id, value.sessionUrl, 'ready', value.emailAddress, value.authentication, value.username);
    return value;
  };
  const addSecret = async (alias, bytes) => asset.add(new Map([[tags.ALIAS, new TextEncoder().encode(alias)], [tags.SECRET, new Uint8Array(bytes)], [tags.ACCESSIBILITY, accessibility.DEVICE_UNLOCKED], [tags.SYNC_TYPE, 0]]));
  const aliases = id => ({ incoming: `tb.jmap.notification_test.db.${id}`, oauth: `tb.oauth.notification_test.db.${id}`, smtp: `tb.smtp.notification_test.db.${id}` });
  const seedOAuth = async (value, expiresAt = 0) => {
    const login = { username: value.username, registration: { provider: 'synthetic' }, tokens: { accessToken: 'synthetic-old-access', refreshToken: 'synthetic-old-refresh', expiresAt } };
    const envelope = await OAuthSecretBox.create(aliases(value.id).oauth, JSON.stringify(login));
    sqlite.prepare('INSERT INTO oauth_credentials VALUES (?, ?)').run(value.id, envelope); return login;
  };
  return { sqlite, db, counts, secrets, state, asset, tags, accessibility, store, AccountStore, OAuthSecretBox, NotificationStore, account, addSecret, aliases, seedOAuth,
    close: () => { if (reader !== sqlite) reader.close(); sqlite.close(); if (directory) fs.rmSync(directory, { recursive: true }); } };
}

test('Notification lease ownership is visible through a separate committed reader and competing owners cannot steal it', async () => {
  const f = fixture({ committedReads: true });
  try {
    await f.NotificationStore.initialize(f.db); const first = f.store().notifications, other = f.store().notifications;
    assert.equal(await first.acquire('first', 1000), true);
    assert.equal(await other.acquire('other', 1100), false);
    await other.release('other'); assert.equal(await other.acquire('other', 1200), false);
    await first.release('first'); assert.equal(await other.acquire('other', 1300), true);
    assert.equal(await first.acquire('expired', 152000), true);
    await other.release('other'); assert.equal(await other.acquire('another', 153000), false);
    await first.release('expired'); assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM mail_check_lease').get().n, 0);
  } finally { f.close(); }
});

test('Close coalesces and reopen waits for picture and queued writes before replacing the database generation', async () => {
  const f = fixture();
  try {
    const account = f.account('lifecycle'), store = f.store();
    const pictures = deferred(), writing = deferred(), entered = deferred();
    store.pictureCache = { whenIdle: () => pictures.promise };
    const oldQueue = store.databaseQueue(f.db);
    const firstClose = store.close();
    assert.equal(store.close(), firstClose, 'concurrent teardown must join one close');
    const write = store.enqueue(async () => {
      entered.resolve(); await writing.promise;
      await f.db.executeSql('UPDATE accounts SET name = ? WHERE id = ?', ['Saved before close', account.id]);
    });
    let opened = false;
    const reopening = store.open({ cacheDir: '/synthetic-cache' }).then(() => { opened = true; });
    await entered.promise;
    assert.equal(opened, false); assert.equal(f.counts.closed, 0);
    pictures.resolve(); await Promise.resolve(); await Promise.resolve();
    assert.equal(opened, false); assert.equal(f.counts.closed, 0, 'the queued write still owns the live database');
    writing.resolve(); await write; await firstClose; await reopening;
    assert.equal(opened, true); assert.equal(f.counts.closed, 1);
    assert.equal((await store.list())[0].name, 'Saved before close');
    assert.equal(f.counts.cache, 1); assert.equal(f.counts.pictures, 1);
    let touchedOldDatabase = false;
    await assert.rejects(oldQueue(async () => { touchedOldDatabase = true; }), /storage is unavailable/);
    assert.equal(touchedOldDatabase, false, 'an obsolete cache handle must fail before using its DB');
    await store.enqueue(async () => {});
  } finally { f.close(); }
});

test('An account metadata read holds the close barrier until its native result is consumed', async () => {
  const f = fixture();
  try {
    f.account('reading'); const store = f.store(), entered = deferred(), reading = deferred();
    const query = f.db.querySql;
    f.db.querySql = async (sql, values) => { entered.resolve(); await reading.promise; return query(sql, values); };
    const accounts = store.list(); await entered.promise;
    const closing = store.close();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(f.counts.closed, 0, 'database close must not race a native read outside the queue');
    reading.resolve(); assert.equal((await accounts)[0].id, 'reading');
    await closing; assert.equal(f.counts.closed, 1);
  } finally { f.close(); }
});

test('OAuth refresh lease commits before its pooled-reader ownership check and preserves account isolation', async () => {
  const f = fixture({ committedReads: true, fastTime: true });
  try {
    const a = f.account('oauth', true), b = f.account('second', true), first = f.store(), other = f.store();
    assert.equal(await first.acquireRefreshLease(a.id, 'first'), true);
    assert.equal(await other.acquireRefreshLease(a.id, 'other'), false);
    assert.equal(await other.acquireRefreshLease(b.id, 'other'), true);
    await other.releaseRefreshLease(a.id, 'other'); assert.equal(await other.acquireRefreshLease(a.id, 'other'), false);
    await first.releaseRefreshLease(a.id, 'first'); assert.equal(await other.acquireRefreshLease(a.id, 'other'), true);
    f.state.now += 61000; assert.equal(await first.acquireRefreshLease(a.id, 'expired'), true);
    await other.releaseRefreshLease(a.id, 'other'); assert.equal(await other.acquireRefreshLease(a.id, 'another'), false);
    await first.releaseRefreshLease(a.id, 'expired'); await other.releaseRefreshLease(b.id, 'other');
    assert.equal(await first.acquireRefreshLease('missing-account', 'missing'), false);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM oauth_refresh_lease').get().n, 0);
  } finally { f.close(); }
});

test('An expired OAuth token refreshes once through pooled SQLite readers without falsely waiting on its own lease', async () => {
  const f = fixture({ committedReads: true, fastTime: true });
  try {
    const a = f.account('oauth', true), store = f.store(); await f.seedOAuth(a);
    let refreshes = 0;
    store.oauthService = { refresh: async () => { refreshes++; return {
      accessToken: 'synthetic-refreshed-access', refreshToken: 'synthetic-refreshed-refresh', expiresAt: f.state.now / 1000 + 3600
    }; } };
    assert.equal(await store.oauthAccessToken(a), 'synthetic-refreshed-access');
    assert.equal(await f.store().oauthAccessToken(a), 'synthetic-refreshed-access');
    assert.equal(refreshes, 1); assert.equal(f.state.waits, 0);
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM oauth_refresh_lease').get().n, 0);
  } finally { f.close(); }
});

test('Explicit enable copies only incoming access; defaults stay off and disable preserves primary/SMTP protection', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('basic'), store = f.store(), alias = f.aliases(a.id);
    await f.addSecret(alias.incoming, new TextEncoder().encode('c3ludGhldGljOm9ubHk=')); await f.addSecret(alias.smtp, new TextEncoder().encode('synthetic-smtp'));
    assert.equal((await store.notificationSettings(a.id)).enabled, false);
    await assert.rejects(store.credentials(a, true).authorization());
    await store.setNotifications(a.id, true);
    assert.equal(f.secrets.get(alias.incoming).get(f.tags.ACCESSIBILITY), 2);
    assert.equal(f.secrets.get(`${alias.incoming}.background`).get(f.tags.ACCESSIBILITY), 1);
    assert.equal(f.secrets.has(`${alias.smtp}.background`), false);
    f.state.locked = true;
    assert.equal(await store.credentials(a, true).authorization(), 'Basic c3ludGhldGljOm9ubHk=');
    await assert.rejects(store.credentials(a).authorization());
    await store.setNotifications(a.id, false);
    assert.equal((await store.notificationSettings(a.id)).enabled, false); assert.equal(f.secrets.has(`${alias.incoming}.background`), false);
    assert.ok(f.secrets.has(alias.incoming)); assert.ok(f.secrets.has(alias.smtp));
    await assert.rejects(store.credentials(a, true).authorization());
  } finally { f.sqlite.close(); }
});

test('Notification-only opening performs no schema/cache cleanup and retains a foreground account still being added', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); f.account('adding'); f.sqlite.exec("UPDATE accounts SET status = 'pending'");
    const before = f.sqlite.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name").all();
    const store = new f.AccountStore('notification_test.db'); await store.openForMailChecks({ cacheDir: '/synthetic' });
    assert.deepEqual(await store.list(), []); assert.equal(f.sqlite.prepare('SELECT status FROM accounts').get().status, 'pending');
    assert.deepEqual(f.sqlite.prepare("SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name").all(), before);
    assert.equal(f.counts.cache, 0); assert.equal(f.counts.pictures, 0); assert.equal(f.counts.outgoingFiles, 0);
    assert.throws(() => store.mail);
    await store.close(); assert.equal(f.counts.closed, 1);
  } finally { f.sqlite.close(); }
});

test('Retained OAuth key survives background revocation and encrypts a foreground-compatible rotated envelope', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), store = f.store(), alias = f.aliases(a.id).oauth;
    const login = await f.seedOAuth(a); await store.setNotifications(a.id, true);
    assert.deepEqual(f.secrets.get(alias).get(f.tags.SECRET), f.secrets.get(`${alias}.background`).get(f.tags.SECRET));
    f.state.locked = true;
    const session = await f.OAuthSecretBox.retain(alias, true);
    await store.setNotifications(a.id, false); assert.equal(f.secrets.has(`${alias}.background`), false);
    const changed = { ...login, tokens: { accessToken: 'rotated', refreshToken: 'rotated-refresh', expiresAt: Date.now() / 1000 + 3600 } };
    const envelope = await session.seal(JSON.stringify(changed)); session.close();
    await assert.rejects(session.open(envelope));
    f.state.locked = false;
    assert.deepEqual(JSON.parse(await f.OAuthSecretBox.open(alias, envelope)), changed);
    await assert.rejects(f.OAuthSecretBox.open(`${alias}.different-account`, envelope));
  } finally { f.sqlite.close(); }
});

test('Send waits for an independent background refresh and reuses its rotated token without a second refresh', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), background = f.store(), sender = f.store();
    await f.seedOAuth(a); await background.setNotifications(a.id, true);
    const entered = deferred(), gate = deferred(); let calls = 0;
    const service = { refresh: async () => { calls++; entered.resolve(); await gate.promise; return { accessToken: 'rotated', refreshToken: 'next-refresh', expiresAt: Date.now() / 1000 + 3600 }; } };
    background.oauthService = service; sender.oauthService = service;
    const first = background.oauthAccessToken(a, undefined, true); await entered.promise;
    let pending = true;
    const sendToken = sender.oauthAccessToken(a, { endpoint: 'smtp://example.test:587', username: a.username });
    const observed = sendToken.then(value => { pending = false; return { value }; }, error => { pending = false; return { error }; });
    await new Promise(resolve => setImmediate(resolve));
    const wasPending = pending;
    gate.resolve(); assert.equal(await first, 'rotated');
    const result = await observed;
    assert.equal(wasPending, true, 'Send must wait for the ongoing refresh instead of failing before SMTP');
    assert.equal(result.error, undefined); assert.equal(result.value, 'rotated');
    assert.equal(calls, 1, 'A waiting Send must never race or replay a rotating refresh token');
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM oauth_refresh_lease').get().n, 0);
  } finally { f.sqlite.close(); }
});

test('Disabling notifications during locked-screen refresh still persists its accepted rotation, and close waits for cleanup', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), foreground = f.store(), background = f.store();
    await f.seedOAuth(a); await foreground.setNotifications(a.id, true); f.state.locked = true;
    const entered = deferred(), gate = deferred();
    background.oauthService = { refresh: async () => { entered.resolve(); await gate.promise; return { accessToken: 'rotated-after-disable', refreshToken: 'next-refresh', expiresAt: Date.now() / 1000 + 3600 }; } };
    const refresh = background.oauthAccessToken(a, undefined, true); await entered.promise;
    await foreground.setNotifications(a.id, false); let closed = false;
    const closing = background.close().then(() => { closed = true; }); await Promise.resolve(); assert.equal(closed, false);
    gate.resolve(); assert.equal(await refresh, 'rotated-after-disable'); await closing;
    f.state.locked = false; assert.equal(await foreground.oauthAccessToken(a), 'rotated-after-disable');
    await assert.rejects(foreground.oauthAccessToken(a, undefined, true));
  } finally { f.sqlite.close(); }
});

test('Expired refresh leases recover and late old owners cannot release another owner’s lease', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), store = f.store();
    f.sqlite.prepare('INSERT INTO oauth_refresh_lease VALUES (?, ?, ?)').run(a.id, 'crashed-owner', Date.now() - 1);
    assert.equal(await store.acquireRefreshLease(a.id, 'new-owner'), true);
    await store.releaseRefreshLease(a.id, 'crashed-owner');
    assert.equal(f.sqlite.prepare('SELECT owner FROM oauth_refresh_lease').get().owner, 'new-owner');
    assert.equal(await f.store().acquireRefreshLease(a.id, 'competitor'), false);
    await store.releaseRefreshLease(a.id, 'new-owner');
  } finally { f.sqlite.close(); }
});

test('A stalled refresh owner bounds Send waiting and keeps its lease without retrying the token request', async () => {
  const f = fixture({ fastTime: true });
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), sender = f.store();
    await f.seedOAuth(a); let calls = 0;
    sender.oauthService = { refresh: async () => { calls++; throw new Error('A competing refresh is forbidden'); } };
    const expires = Date.now() + 60000;
    f.sqlite.prepare('INSERT INTO oauth_refresh_lease VALUES (?, ?, ?)').run(a.id, 'other-process', expires);
    const keysBefore = f.counts.keysCleared;
    await assert.rejects(sender.oauthAccessToken(a, { endpoint: 'smtp://example.test:587', username: a.username }), error => error.code === 'network');
    assert.equal(f.state.waits, 40); assert.equal(f.state.waitMs, 20000); assert.equal(calls, 0);
    assert.deepEqual({ ...f.sqlite.prepare('SELECT owner, expires FROM oauth_refresh_lease').get() }, { owner: 'other-process', expires });
    assert.equal(f.counts.keysCleared - keysBefore, 2, 'Both initial and retained token keys are cleared on timeout');
    await sender.close(); assert.equal(f.counts.closed, 1);
  } finally { f.sqlite.close(); }
});

test('Removing an account while Send waits cancels token release and cannot resurrect the account', async () => {
  let f;
  f = fixture({ fastTime: true, onWait: () => { f.sqlite.exec("UPDATE accounts SET status = 'deleting'"); } });
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), sender = f.store();
    await f.seedOAuth(a); let calls = 0;
    sender.oauthService = { refresh: async () => { calls++; throw new Error('Removed accounts must not refresh'); } };
    f.sqlite.prepare('INSERT INTO oauth_refresh_lease VALUES (?, ?, ?)').run(a.id, 'other-process', Date.now() + 60000);
    const original = f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope;
    await assert.rejects(sender.oauthAccessToken(a, { endpoint: 'smtp://example.test:587', username: a.username }), error => error.code === 'authenticationRequired');
    assert.equal(f.state.waits, 1); assert.equal(calls, 0);
    assert.equal(f.sqlite.prepare('SELECT status FROM accounts').get().status, 'deleting');
    assert.equal(f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope, original);
    assert.equal(f.sqlite.prepare('SELECT owner FROM oauth_refresh_lease').get().owner, 'other-process');
  } finally { f.sqlite.close(); }
});

test('A background waiter observes notification disable before releasing another owner’s token', async () => {
  let f;
  f = fixture({ fastTime: true, onWait: () => { f.sqlite.exec('UPDATE mail_notifications SET enabled = 0'); } });
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), store = f.store();
    await f.seedOAuth(a); await store.setNotifications(a.id, true); let calls = 0;
    store.oauthService = { refresh: async () => { calls++; throw new Error('Disabled background work must not refresh'); } };
    f.sqlite.prepare('INSERT INTO oauth_refresh_lease VALUES (?, ?, ?)').run(a.id, 'other-process', Date.now() + 60000);
    await assert.rejects(store.oauthAccessToken(a, undefined, true), error => error.code === 'network');
    assert.equal(f.state.waits, 1); assert.equal(calls, 0);
    assert.equal(f.sqlite.prepare('SELECT owner FROM oauth_refresh_lease').get().owner, 'other-process');
  } finally { f.sqlite.close(); }
});

test('A waiting Send rejects a changed login binding instead of releasing the refreshed bearer token', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), sender = f.store();
    const login = await f.seedOAuth(a);
    f.sqlite.prepare('INSERT INTO oauth_refresh_lease VALUES (?, ?, ?)').run(a.id, 'other-process', Date.now() + 60000);
    const waiting = sender.oauthAccessToken(a, { endpoint: 'smtp://example.test:587', username: a.username });
    const observed = waiting.then(value => ({ value }), error => ({ error }));
    await new Promise(resolve => setImmediate(resolve));
    login.username = 'different@example.test'; login.tokens = { accessToken: 'must-not-release', expiresAt: Date.now() / 1000 + 3600 };
    const changed = await f.OAuthSecretBox.seal(f.aliases(a.id).oauth, JSON.stringify(login));
    f.sqlite.prepare('UPDATE oauth_credentials SET envelope = ? WHERE account_id = ?').run(changed, a.id);
    const result = await observed;
    assert.equal(result.error?.code, 'authenticationRequired'); assert.equal(result.value, undefined);
    assert.equal(f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope, changed);
  } finally { f.sqlite.close(); }
});

test('OAuth reconnect replaces only the encrypted credential envelope and preserves the account, cached mail, drafts and opt-in', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), store = f.store(), alias = f.aliases(a.id);
    const login = await f.seedOAuth(a); await store.setNotifications(a.id, true);
    await f.addSecret(alias.smtp, new TextEncoder().encode('synthetic-smtp-settings'));
    f.sqlite.exec("CREATE TABLE mail_cache (account_id TEXT, payload TEXT); CREATE TABLE outgoing_drafts (account_id TEXT, payload TEXT); CREATE TABLE account_preferences (name TEXT, account_id TEXT)");
    f.sqlite.prepare('INSERT INTO mail_cache VALUES (?, ?)').run(a.id, 'Downloaded synthetic body');
    f.sqlite.prepare('INSERT INTO outgoing_drafts VALUES (?, ?)').run(a.id, 'Unsent synthetic draft');
    f.sqlite.prepare('INSERT INTO account_preferences VALUES (?, ?)').run('last_visited', a.id);
    const tables = ['accounts', 'mail_cache', 'outgoing_drafts', 'account_preferences', 'mail_notifications'];
    const before = tables.map(table => f.sqlite.prepare(`SELECT * FROM ${table}`).all());
    const secrets = [...f.secrets].map(([name, value]) => [name, [...value].map(([tag, bytes]) => [tag, bytes instanceof Uint8Array ? Buffer.from(bytes).toString('hex') : bytes])]);
    login.tokens = { accessToken: 'reconnected-access', refreshToken: 'reconnected-refresh', expiresAt: Date.now() / 1000 + 3600 };
    await store.replaceOAuth(a, { id: a.serverId }, login);
    assert.equal(await store.oauthAccessToken(a), 'reconnected-access');
    assert.equal(await store.oauthAccessToken(a, undefined, true), 'reconnected-access');
    assert.deepEqual(tables.map(table => f.sqlite.prepare(`SELECT * FROM ${table}`).all()), before);
    assert.deepEqual([...f.secrets].map(([name, value]) => [name, [...value].map(([tag, bytes]) => [tag, bytes instanceof Uint8Array ? Buffer.from(bytes).toString('hex') : bytes])]), secrets);
  } finally { f.sqlite.close(); }
});

test('Reconnect rejects another account, provider, server or removed identity before changing its credentials', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), store = f.store();
    const login = await f.seedOAuth(a, Date.now() / 1000 + 3600);
    const original = f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope;
    for (const attempt of [
      { account: a, server: { id: a.serverId }, login: { ...login, username: 'other@example.test' } },
      { account: a, server: { id: 'other-server' }, login },
      { account: a, server: { id: a.serverId }, login: { ...login, registration: { provider: 'other-provider' } } },
      { account: { ...a, username: 'other@example.test' }, server: { id: a.serverId }, login: { ...login, username: 'other@example.test' } },
      { account: { ...a, emailAddress: 'other@example.test' }, server: { id: a.serverId }, login },
      { account: { ...a, sessionUrl: 'imaps://other.example.test:993' }, server: { id: a.serverId }, login }
    ]) {
      await assert.rejects(store.replaceOAuth(attempt.account, attempt.server, attempt.login), error => error.code === 'authenticationRequired');
      assert.equal(f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope, original);
    }
    f.sqlite.exec("UPDATE accounts SET status = 'deleting'");
    await assert.rejects(store.replaceOAuth(a, { id: a.serverId }, login), error => error.code === 'authenticationRequired');
    assert.equal(f.sqlite.prepare('SELECT envelope FROM oauth_credentials').get().envelope, original);
  } finally { f.sqlite.close(); }
});

test('A late token refresh cannot overwrite a successfully reconnected account', async () => {
  const f = fixture();
  try {
    await f.NotificationStore.initialize(f.db); const a = f.account('oauth', true), oldStore = f.store(), reconnect = f.store();
    const login = await f.seedOAuth(a), entered = deferred(), gate = deferred();
    oldStore.oauthService = { refresh: async () => { entered.resolve(); await gate.promise;
      return { accessToken: 'obsolete-rotation', refreshToken: 'obsolete-refresh', expiresAt: Date.now() / 1000 + 3600 }; } };
    const old = oldStore.oauthAccessToken(a); const observed = old.then(value => ({ value }), error => ({ error })); await entered.promise;
    login.tokens = { accessToken: 'new-sign-in', refreshToken: 'new-sign-in-refresh', expiresAt: Date.now() / 1000 + 3600 };
    await reconnect.replaceOAuth(a, { id: a.serverId }, login);
    gate.resolve(); assert.equal((await observed).error?.code, 'authenticationRequired');
    assert.equal(await reconnect.oauthAccessToken(a), 'new-sign-in');
    assert.equal(f.sqlite.prepare('SELECT count(*) AS n FROM oauth_refresh_lease').get().n, 0);
  } finally { f.sqlite.close(); }
});
