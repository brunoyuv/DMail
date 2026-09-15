const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('../.tools/test/node_modules/typescript');

const copy = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let index = 0; index < 120; index++) await Promise.resolve(); };
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };

// Execute the actual service, engine and model against synthetic accounts. The
// fake clock makes the native event heartbeat and minute tick deterministic;
// no Harmony services, credentials, network or message cache are accessed.
function fixture() {
  const state = { now: 1800000000000, permitted: true, leaseBusy: false, owner: '', scheduleError: false,
    supported: true, eventChanged: true, newMessages: 0, unreadEmails: 37, checks: 0, checkError: false,
    networkStarts: [], badgeBeginError: false, badgeRecordError: false, opens: 0, closes: 0, permissionGates: [], locked: false,
    authorization: 'Synthetic fixture only', credentialGates: [] };
  const observed = { schedules: [], snapshots: [], stopped: [], credentials: [], watchAuthorizations: [], published: [], badges: [], badgeRecords: [] };
  const badgeCounts = new Map();
  const storageValues = new Map();
  const AppStorage = { get: key => storageValues.get(key), setOrCreate: (key, value) => storageValues.set(key, value) };
  const timers = new Map(); let nextTimer = 1, nextId = 1;
  const timer = (callback, delay, repeat = false) => {
    const id = nextTimer++; timers.set(id, { callback, due: state.now + delay, delay, repeat }); return id;
  };
  class Clock extends Date { static now() { return state.now; } }
  const accounts = [{ id: 'synthetic-account', serverId: 'default', sessionUrl: 'imaps://example.test:993', username: 'synthetic' }];
  let settings;
  const repository = {
    list: async () => settings.map(copy),
    get: async id => copy(settings.find(value => value.accountId === id) || { accountId: id, enabled: false }),
    acquire: async owner => {
      if (state.leaseBusy || state.owner) return false;
      state.owner = owner; return true;
    },
    release: async owner => { if (state.owner === owner) state.owner = ''; },
    complete: async (id, revision, check, now) => {
      const value = settings.find(value => value.accountId === id);
      if (!value?.enabled || value.revision !== revision) return false;
      value.lastAttempt = now;
      if (!check) { value.failures++; return true; }
      if (value.cursor && check.newMessages > 0) value.noticeVersion++;
      value.cursor = check.state; value.mailboxId = check.mailboxId; value.lastCheck = now; value.failures = 0;
      return true;
    },
    acknowledge: async (id, version) => {
      const value = settings.find(value => value.accountId === id);
      if (value?.enabled && value.noticeVersion === version) value.acknowledgedVersion = version;
    }
  };
  class AccountStore {
    notifications = repository;
    badges = {
      beginCheck: async accountId => {
        if (state.badgeBeginError) throw new Error('Synthetic count guard write failure');
        return settings.find(value => value.accountId === accountId)?.enabled ? { revision: 1, settingsRevision: 1 } : null;
      },
      record: async (accountId, guard, count, mailboxId, checkedAt) => {
        if (state.badgeRecordError) throw new Error('Synthetic count write failure');
        if (guard && settings.find(value => value.accountId === accountId)?.enabled) {
          observed.badgeRecords.push({ accountId, count, mailboxId, checkedAt }); badgeCounts.set(accountId, count);
        }
      },
      total: async () => {
        const enabled = settings.filter(value => value.enabled && accounts.some(account => account.id === value.accountId));
        return enabled.some(value => !badgeCounts.has(value.accountId)) ? null :
          enabled.reduce((total, value) => total + badgeCounts.get(value.accountId), 0);
      }
    };
    async openForMailChecks() { state.opens++; }
    async list() { return accounts.map(copy); }
    credentials(account, background = false) {
      return { authorization: async () => {
        observed.credentials.push({ accountId: account.id, background });
        const gate = state.credentialGates.shift(); if (gate) await gate;
        if (state.locked && !background) throw new Error('Synthetic foreground credential locked');
        return state.authorization;
      } };
    }
    async close() { state.closes++; }
  }
  class NativeImapClient {
    constructor(endpoint, credentials) { this.credentials = credentials; this.started = new Set(); }
    async watchInbox(id) {
      if (!this.started.has(id)) {
        observed.watchAuthorizations.push({ id, authorization: await this.credentials.authorization() }); this.started.add(id);
        state.networkStarts.push({ kind: 'watch', at: state.now });
      }
      observed.snapshots.push(id);
      const changed = state.eventChanged; state.eventChanged = false;
      return { supported: state.supported, changed };
    }
    async checkInbox() {
      await this.credentials.authorization(); state.networkStarts.push({ kind: 'check', at: state.now }); state.checks++;
      if (state.checkError) throw new Error('Synthetic check failure');
      return { state: `checkpoint-${state.checks}`, mailboxId: 'INBOX', newMessages: state.newMessages, unreadEmails: state.unreadEmails };
    }
  }
  const platform = {
    isEnabled: async () => { const gate = state.permissionGates.shift(); if (gate) await gate; return state.permitted; },
    schedule: async (_, minutes) => { observed.schedules.push(minutes); if (state.scheduleError) throw new Error('Synthetic registration failure'); },
    publish: async (_, id, accountId) => { observed.published.push({ id, accountId }); },
    setUnreadBadge: async value => observed.badges.push(value),
    cancel: async () => {}
  };
  const loaded = new Map();
  function load(file) {
    file = path.resolve(file); if (loaded.has(file)) return loaded.get(file);
    const source = fs.readFileSync(file, 'utf8');
    const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
    const module = { exports: {} }; loaded.set(file, module.exports);
    new Function('require', 'module', 'exports', 'Date', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'AppStorage', code)(name => {
      if (name === '@kit.ArkTS') return { util: { generateRandomUUID: () => `synthetic-owner-${nextId++}` } };
      if (name.endsWith('/AccountStore')) return { AccountStore };
      if (name.endsWith('/MailCache')) return { MailCache: { mutationRevision: () => 0 } };
      if (name.endsWith('/NativeImapClient')) return { NativeImapClient, stopInboxWatch: async id => { observed.stopped.push(id); } };
      if (name.endsWith('/NativeJmapAccountCore')) return { NativeJmapAccountCore: class { constructor() { throw new Error('Unexpected JMAP call'); } } };
      if (name.endsWith('/JmapClient')) return { JmapError: class extends Error {} };
      if (name.endsWith('/MailOperations')) return { MailOperations: { overlay: (_id, mail) => mail } };
      if (name === './NotificationPlatform') return { NotificationPlatform: platform };
      assert.ok(name.startsWith('.'), `Unexpected module ${name}`);
      const base = path.resolve(path.dirname(file), name); return load(fs.existsSync(`${base}.ts`) ? `${base}.ts` : `${base}.ets`);
    }, module, module.exports, Clock,
    (callback, delay) => timer(callback, delay), id => timers.delete(id),
    (callback, delay) => timer(callback, delay, true), id => timers.delete(id), AppStorage);
    return module.exports;
  }
  const root = 'harmony/entry/src/main/ets/mail/notifications';
  const { NotificationAccountState } = load(`${root}/NotificationModel.ts`);
  settings = [Object.assign(new NotificationAccountState(), { accountId: accounts[0].id, enabled: true, notificationId: 1, revision: 1 })];
  const { MailNotificationService: service } = load(`${root}/MailNotificationService.ets`);
  const { MailInboxUpdates: updates } = load(`${root}/MailInboxUpdates.ets`);
  const advance = async milliseconds => {
    const target = state.now + milliseconds;
    await flush();
    for (;;) {
      const next = Array.from(timers).sort((a, b) => a[1].due - b[1].due)[0];
      if (!next || next[1].due > target) break;
      const [id, value] = next; state.now = value.due;
      if (value.repeat) value.due += value.delay; else timers.delete(id);
      value.callback(); await flush();
    }
    state.now = target; await flush();
  };
  const settle = async promise => {
    let done = false, value, failure;
    promise.then(result => { done = true; value = result; }, error => { done = true; failure = error; });
    for (let i = 0; i < 100; i++) {
      await flush(); if (done) { if (failure) throw failure; return value; }
      const next = [...timers.values()].sort((a,b) => a.due-b.due)[0];
      assert.ok(next, 'Synthetic service wait needs a pending timer');
      await advance(Math.max(0, next.due-state.now));
    }
    assert.fail('Synthetic service operation did not settle');
  };
  const stop = async () => { service.onBackground(); await advance(1000); assert.equal(state.opens, state.closes); };
  return { service, run: (...args) => settle(service.run(...args)), updates, storageValues, state, settings, accounts, observed, badgeCounts, timers, advance, stop, context: {} };
}

test('Foreground creates one persistent watch and background closes it, its store and its timer', async () => {
  const f = fixture();
  try {
    f.service.onForeground(f.context); f.service.onForeground(f.context); await flush();
    assert.deepEqual(f.observed.schedules, [120]);
    assert.equal(new Set(f.observed.snapshots).size, 1);
    const first = f.observed.snapshots[0];
    // The ordinary foreground tick may briefly hold the same durable lease;
    // the ready event must survive and retry after its ten-second contention delay.
    await f.advance(10000);
    assert.ok(f.observed.snapshots.length >= 4);
    assert.equal(new Set(f.observed.snapshots).size, 1);
    assert.ok(f.state.checks > 0);
    assert.ok(f.observed.credentials.every(value => !value.background));
    await f.stop(); assert.ok(f.observed.stopped.includes(first)); assert.equal(f.timers.size, 0);
    const calls = f.observed.snapshots.length;
    await f.advance(120000); assert.equal(f.observed.snapshots.length, calls);
    f.state.eventChanged = true;
    f.service.onForeground(f.context); await flush();
    assert.notEqual(f.observed.snapshots.at(-1), first);
  } finally { await f.stop(); }
});

test('Denied OS permission starts no watch or check, and revocation closes an active watch', async () => {
  const f = fixture();
  try {
    f.state.permitted = false; f.service.onForeground(f.context); await flush();
    assert.deepEqual(f.observed.schedules, [null]); assert.equal(f.observed.snapshots.length, 0); assert.equal(f.state.checks, 0);
    f.state.permitted = true; await f.service.settingsChanged(f.context); await flush();
    assert.equal(f.observed.schedules.at(-1), 120); assert.equal(new Set(f.observed.snapshots).size, 1);
    const watch = f.observed.snapshots[0], checks = f.state.checks;
    f.state.permitted = false; await f.advance(60000);
    assert.ok(f.observed.stopped.includes(watch)); assert.equal(f.state.checks, checks);
    const snapshots = f.observed.snapshots.length; await f.advance(60000);
    assert.equal(f.observed.snapshots.length, snapshots);
  } finally { await f.stop(); }
});

test('Changing account settings replaces its watch, while disabling removes watch and scheduled work', async () => {
  const f = fixture();
  try {
    f.service.onForeground(f.context); await flush(); const first = f.observed.snapshots[0];
    f.settings[0].foregroundMinutes = 15; f.settings[0].backgroundMinutes = 240; f.settings[0].revision++;
    await f.service.settingsChanged(f.context); await f.advance(6000);
    assert.equal(f.observed.schedules.at(-1), 240); assert.ok(f.observed.stopped.includes(first));
    const second = f.observed.snapshots.at(-1); assert.notEqual(second, first);
    f.settings[0].enabled = false; f.settings[0].revision++;
    await f.service.settingsChanged(f.context); await flush();
    assert.equal(f.observed.schedules.at(-1), null); assert.ok(f.observed.stopped.includes(second));
    const checks = f.state.checks; await f.advance(60000); assert.equal(f.state.checks, checks);
  } finally { await f.stop(); }
});

test('Muting an account dismisses its existing in-app banner before OS permission reconciliation completes', async () => {
  const f = fixture(), permission = deferred();
  f.storageValues.set('mailBannerAccountId', f.accounts[0].id);
  f.storageValues.set('mailBannerAt', f.state.now);
  f.settings[0].enabled = false; f.settings[0].revision++;
  f.state.permissionGates.push(permission.promise);
  const updating = f.service.settingsChanged(f.context);
  await flush();
  assert.equal(f.storageValues.get('mailBannerAccountId'), '');
  assert.equal(f.storageValues.has('mailNotificationAccountId'), false);
  assert.equal(f.state.checks, 0);
  permission.resolve(); await updating;
  assert.equal(f.state.opens, f.state.closes);
});

test('A consumed native arrival remains pending while another process owns the check lease', async () => {
  const f = fixture();
  try {
    f.state.leaseBusy = true; f.service.onForeground(f.context); await flush();
    assert.equal(f.state.checks, 0); assert.equal(f.state.eventChanged, false);
    await f.advance(9000); assert.equal(f.state.checks, 0);
    f.state.leaseBusy = false; await f.advance(1000);
    assert.equal(f.state.checks, 1); assert.equal(f.settings[0].cursor, 'checkpoint-1');
    await f.advance(20000); assert.equal(f.state.checks, 1);
  } finally { await f.stop(); }
});

test('An unsupported watch falls back to the selected interval without retrying each heartbeat', async () => {
  const f = fixture();
  try {
    f.state.supported = false; f.settings[0].foregroundMinutes = 15;
    f.service.onForeground(f.context); await f.advance(3000);
    assert.equal(f.state.checks, 1); const snapshots = f.observed.snapshots.length;
    await f.advance(14 * 60000); assert.equal(f.state.checks, 1); assert.equal(f.observed.snapshots.length, snapshots);
    await f.advance(2 * 60000); assert.equal(f.state.checks, 2); assert.equal(f.observed.snapshots.length, snapshots);
  } finally { await f.stop(); }
});

test('Background registration errors reach the settings caller as a safe error', async () => {
  const f = fixture();
  try {
    f.state.scheduleError = true;
    await assert.rejects(f.service.settingsChanged(f.context), error => error.message === 'Background checking could not be scheduled');
    assert.equal(f.state.opens, f.state.closes); assert.equal(f.observed.snapshots.length, 0); assert.equal(f.state.checks, 0);
    f.state.scheduleError = false; await f.service.settingsChanged(f.context);
    assert.equal(f.observed.schedules.at(-1), 120);
  } finally { await f.stop(); }
});

test('A locked background check uses explicit background access and never starts a foreground watch', async () => {
  const f = fixture();
  try {
    f.state.locked = true;
    assert.equal(await f.run(f.context, true), true);
    assert.equal(f.state.checks, 1); assert.equal(f.observed.snapshots.length, 0);
    assert.deepEqual(f.observed.credentials, [{ accountId: f.accounts[0].id, background: true }]);
    assert.equal(f.state.opens, f.state.closes);
    await f.run(f.context, false, () => false, f.accounts[0].id);
    assert.equal(f.state.checks, 1);
    assert.deepEqual(f.observed.credentials.at(-1), { accountId: f.accounts[0].id, background: false });
    assert.equal(f.settings[0].failures, 1);
  } finally { await f.stop(); }
});

test('An older reconciliation cannot overwrite a later frequency choice after an asynchronous permission check', async () => {
  const f = fixture(), gate = deferred();
  try {
    f.state.permissionGates.push(gate.promise);
    const first = f.service.settingsChanged(f.context); await flush();
    f.settings[0].backgroundMinutes = 240; f.settings[0].revision++;
    const second = f.service.settingsChanged(f.context); await flush();
    gate.resolve(); await Promise.all([first, second]);
    assert.equal(f.observed.schedules.at(-1), 240);
  } finally { gate.resolve(); await f.stop(); }
});

test('The visible inbox receives IDLE readiness and arrivals with alerts disabled and notification permission denied', async () => {
  const f = fixture();
  try {
    f.settings[0].enabled = false; f.state.permitted = false;
    f.service.setVisibleAccount(f.accounts[0].id);
    await flush(); assert.equal(f.observed.snapshots.length, 0, 'UI registration must not start a background watcher');
    f.service.onForeground(f.context); await flush();
    assert.equal(f.updates.revision(f.accounts[0].id), 1);
    await f.advance(3000); assert.equal(f.updates.revision(f.accounts[0].id), 1, 'quiet snapshots must not request list refreshes');
    f.state.eventChanged = true; await f.advance(1000);
    assert.equal(f.updates.revision(f.accounts[0].id), 2);
    assert.equal(new Set(f.observed.snapshots).size, 1);
    assert.equal(f.state.checks, 0); assert.deepEqual(f.observed.published, []);
    assert.deepEqual(f.observed.schedules, [null]);
    assert.ok(f.observed.credentials.every(value => value.background === false));
  } finally { await f.stop(); }
});

test('An arrival refresh hint is independent of the notification check lease and unread count', async () => {
  const f = fixture();
  try {
    f.state.leaseBusy = true; f.service.setVisibleAccount(f.accounts[0].id);
    f.service.onForeground(f.context); await flush();
    assert.equal(f.updates.revision(f.accounts[0].id), 1);
    f.state.eventChanged = true; await f.advance(1000);
    assert.equal(f.updates.revision(f.accounts[0].id), 2);
    f.state.leaseBusy = false; await f.advance(10000);
    assert.equal(f.state.checks, 1); assert.deepEqual(f.observed.published, []);
    assert.equal(f.updates.revision(f.accounts[0].id), 2, 'a zero-unread metadata check cannot consume or duplicate arrival hints');
  } finally { await f.stop(); }
});

test('Visible account changes stop inactive watches and keep refresh revisions account-local', async () => {
  const f = fixture();
  try {
    f.settings[0].enabled = false;
    f.accounts.push({ ...f.accounts[0], id: 'second-synthetic-account' });
    f.service.setVisibleAccount(f.accounts[0].id); f.service.onForeground(f.context); await flush();
    const firstWatch = f.observed.snapshots[0];
    f.state.eventChanged = true; f.service.setVisibleAccount(f.accounts[1].id); await flush(); await f.advance(3000);
    assert.ok(f.observed.stopped.includes(firstWatch));
    assert.equal(f.updates.revision(f.accounts[0].id), 1);
    assert.equal(f.updates.revision(f.accounts[1].id), 1);
    f.service.setVisibleAccount(''); await flush();
    const count = f.observed.snapshots.length; await f.advance(1000);
    assert.equal(f.observed.snapshots.length, count);
  } finally { await f.stop(); }
});

test('A visible non-IDLE inbox refreshes at its foreground interval and on resume without enabling background alerts', async () => {
  const f = fixture();
  try {
    f.state.supported = false; f.state.permitted = false;
    f.settings[0].enabled = false; f.settings[0].foregroundMinutes = 15;
    f.service.setVisibleAccount(f.accounts[0].id); f.service.onForeground(f.context); await flush(); await f.advance(0);
    assert.equal(f.updates.revision(f.accounts[0].id), 1);
    await f.advance(14 * 60000); assert.equal(f.updates.revision(f.accounts[0].id), 1);
    await f.advance(60000); assert.equal(f.updates.revision(f.accounts[0].id), 2);
    await f.stop(); const count = f.updates.revision(f.accounts[0].id);
    await f.advance(15 * 60000); assert.equal(f.updates.revision(f.accounts[0].id), count);
    f.service.onForeground(f.context); await flush(); await f.advance(0);
    assert.equal(f.updates.revision(f.accounts[0].id), count + 1);
    assert.equal(f.state.checks, 0); assert.deepEqual(f.observed.published, []);
  } finally { await f.stop(); }
});

test('Background scheduling failure cannot block immediate visible-inbox IDLE readiness', async () => {
  const f = fixture();
  try {
    f.settings[0].enabled = false; f.state.scheduleError = true;
    f.service.setVisibleAccount(f.accounts[0].id); f.service.onForeground(f.context); await flush();
    assert.equal(f.updates.revision(f.accounts[0].id), 1);
    assert.equal(new Set(f.observed.snapshots).size, 1);
    assert.equal(f.state.checks, 0);
  } finally { await f.stop(); }
});

test('A confirmed new arrival publishes a repeatable alert, unread badge and foreground banner once', async () => {
  const f = fixture();
  try {
    f.service.onForeground(f.context); await f.advance(10000);
    assert.ok(f.settings[0].cursor); assert.equal(f.observed.published.length, 0);
    f.state.eventChanged = false; f.state.newMessages = 1;
    assert.equal(await f.run(f.context, false, () => false, f.accounts[0].id), true);
    assert.equal(f.observed.published.length, 1); assert.equal(f.observed.badges.at(-1), 37);
    assert.equal(f.observed.badges.includes(1), false, 'Publication must not replace a full total with one');
    assert.equal(f.storageValues.get('mailBannerAccountId'), f.accounts[0].id);
    assert.equal(f.storageValues.get('mailBannerRevision'), 1);
    f.state.newMessages = 0;
    await f.run(f.context, false, () => false, f.accounts[0].id);
    assert.equal(f.observed.published.length, 1); assert.equal(f.storageValues.get('mailBannerRevision'), 1);
  } finally { await f.stop(); }
});

test('A silent baseline writes the full unread count even without publishing an arrival alert', async () => {
  const f = fixture();
  assert.equal(await f.run(f.context, true), true);
  assert.equal(f.state.checks, 1); assert.equal(f.observed.published.length, 0);
  assert.equal(f.observed.badgeRecords[0].count, 37);
  assert.equal(f.observed.badges.at(-1), 37);
  assert.equal(f.storageValues.has('mailBannerAccountId'), false);
  assert.equal(f.state.opens, f.state.closes);
});

test('Badge reconciliation sums enabled accounts, excludes muted accounts, and clears when all are muted', async () => {
  const f = fixture();
  f.accounts.push({ ...f.accounts[0], id: 'second-account' }, { ...f.accounts[0], id: 'muted-account' });
  f.settings.push({ ...f.settings[0], accountId: 'second-account', notificationId: 2 },
    { ...f.settings[0], accountId: 'muted-account', notificationId: 3, enabled: false });
  f.badgeCounts.set(f.accounts[0].id, 37); f.badgeCounts.set('second-account', 8); f.badgeCounts.set('muted-account', 1000);
  await f.service.settingsChanged(f.context);
  assert.equal(f.observed.badges.at(-1), 45); assert.equal(f.state.checks, 0);
  f.settings[0].enabled = false; f.settings[0].revision++;
  await f.service.settingsChanged(f.context); assert.equal(f.observed.badges.at(-1), 8);
  f.settings[1].enabled = false; f.settings[1].revision++;
  await f.service.settingsChanged(f.context); assert.equal(f.observed.badges.at(-1), 0);
  assert.equal(f.state.opens, f.state.closes);
});

test('Count guard or record failures retain a successful arrival check and its notification', async () => {
  for (const stage of ['badgeBeginError', 'badgeRecordError']) {
    const f = fixture();
    f.settings[0].cursor = 'earlier-baseline'; f.state.newMessages = 1;
    f.badgeCounts.set(f.accounts[0].id, 19); f.state[stage] = true;
    assert.equal(await f.run(f.context, true, () => false, f.accounts[0].id), true, stage);
    assert.equal(f.state.checks, 1); assert.equal(f.observed.published.length, 1);
    assert.equal(f.settings[0].cursor, 'checkpoint-1'); assert.equal(f.observed.badges.at(-1), 19);
    assert.equal(f.state.opens, f.state.closes);
  }
});

test('A reconciliation paused at permission lookup cannot start a watch after alerts were disabled', async () => {
  const f = fixture(), gate = deferred();
  try {
    // First permission read belongs to settingsChanged; hold the subsequent tick.
    f.state.permissionGates.push(Promise.resolve(), gate.promise);
    f.service.onForeground(f.context); await flush();
    assert.equal(f.observed.snapshots.length, 0);
    f.settings[0].enabled = false; f.settings[0].revision++;
    await f.service.settingsChanged(f.context);
    gate.resolve(); await flush(); await f.advance(0);
    assert.equal(f.observed.snapshots.length, 0, 'Obsolete settings must never start a native watch');
    assert.equal(f.observed.credentials.length, 0);
    assert.equal(f.state.checks, 0);
  } finally { gate.resolve(); await f.stop(); }
});

test('A pending IDLE arrival respects persisted failure backoff without opening stores every ten seconds', async () => {
  const f = fixture();
  try {
    f.state.checkError = true;
    f.service.onForeground(f.context); await f.advance(10000);
    assert.equal(f.state.checks, 1); assert.equal(f.settings[0].failures, 1);
    const opens = f.state.opens, snapshots = f.observed.snapshots.length;
    await f.advance(49000); // End before the ordinary one-minute reconciliation.
    assert.equal(f.state.opens, opens, 'Backed-off checks must not repeatedly open encrypted stores');
    assert.equal(f.state.checks, 1);
    assert.ok(f.observed.snapshots.length > snapshots, 'The persistent native watch still consumes arrival flags');
    f.state.checkError = false;
    const due = f.settings[0].lastAttempt + 10 * 60000;
    await f.advance(due - f.state.now + 1000);
    assert.equal(f.state.checks, 2, 'The retained arrival retries when its persisted backoff expires');
    assert.equal(f.settings[0].failures, 0);
  } finally { await f.stop(); }
});

test('Explicit reconnect replaces only that account watch and ordinary settings rereads retain live sessions', async () => {
  const f = fixture();
  f.accounts.push({ ...f.accounts[0], id: 'second-synthetic-account' });
  f.settings.push({ ...f.settings[0], accountId: f.accounts[1].id, notificationId: 2 });
  f.state.eventChanged = false;
  try {
    f.service.onForeground(f.context); await f.advance(12000);
    assert.equal(f.observed.watchAuthorizations.length, 2);
    const first = f.observed.watchAuthorizations[0].id, second = f.observed.watchAuthorizations[1].id;
    f.state.authorization = 'Synthetic replacement only';
    await f.service.settingsChanged(f.context); await f.advance(1000);
    assert.equal(f.observed.watchAuthorizations.length, 2, 'Ordinary rereads or token rotation do not restart authenticated sessions');
    f.service.credentialsChanged(f.accounts[0].id); await f.advance(3000);
    assert.equal(f.observed.watchAuthorizations.length, 3);
    assert.ok(f.observed.stopped.includes(first)); assert.ok(!f.observed.stopped.includes(second));
    assert.notEqual(f.observed.watchAuthorizations[2].id, first);
    assert.equal(f.observed.watchAuthorizations[2].authorization, 'Synthetic replacement only');
  } finally { await f.stop(); }
});

test('Stopping while IMAP credentials are pending cannot start a watch or check after authorization resolves', async () => {
  for (const operation of ['watch', 'check']) {
    const f = fixture(), gate = deferred(); let stopped = false;
    f.state.credentialGates.push(gate.promise);
    try {
      let running;
      if (operation === 'watch') {
        f.settings[0].enabled = false; f.service.setVisibleAccount(f.accounts[0].id);
        f.service.onForeground(f.context);
      } else { running = f.service.run(f.context, true, () => stopped); }
      await flush(); assert.equal(f.observed.credentials.length, 1);
      stopped = true; f.service.onBackground(); gate.resolve();
      if (running) await running;
      await f.advance(1000);
      assert.equal(f.observed.snapshots.length, 0, operation);
      assert.equal(f.state.checks, 0, operation);
    } finally { gate.resolve(); await f.stop(); }
  }
});


test('Automatic account checks and IDLE establishment share three-second spacing while quiet IDLE snapshots stay local', async () => {
  const f = fixture();
  f.accounts.push({ ...f.accounts[0], id: 'second-synthetic-account' });
  f.settings.push({ ...f.settings[0], accountId: f.accounts[1].id, notificationId: 2 });
  try {
    f.service.onForeground(f.context); await f.advance(15000);
    assert.ok(f.state.networkStarts.length >= 3);
    for (let i = 1; i < f.state.networkStarts.length; i++) {
      assert.ok(f.state.networkStarts[i].at - f.state.networkStarts[i-1].at >= 3000);
    }
    const calls = f.state.networkStarts.length, snapshots = f.observed.snapshots.length;
    await f.advance(30000);
    assert.equal(f.state.networkStarts.length, calls, 'Quiet foreground does not create extra server requests');
    assert.ok(f.observed.snapshots.length > snapshots, 'Existing local IDLE event reads remain available');
  } finally { await f.stop(); }
});
test('Backgrounding retires waiting automatic watch/check starts immediately without a new server request', async () => {
  const f = fixture();
  f.accounts.push({ ...f.accounts[0], id: 'second-synthetic-account' });
  f.settings.push({ ...f.settings[0], accountId: f.accounts[1].id, notificationId: 2 });
  f.service.onForeground(f.context); await flush();
  assert.equal(f.state.networkStarts.length, 1);
  await f.stop(); await f.advance(10000);
  assert.equal(f.state.networkStarts.length, 1); assert.equal(f.state.checks, 0); assert.equal(f.timers.size, 0);
});
