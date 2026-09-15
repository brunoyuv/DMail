const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
function load(file, modules) {
  const source = fs.readFileSync(file, 'utf8');
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
  const module = { exports: {} };
  new Function('require', 'module', 'exports', code)(name => {
    assert.ok(modules[name], `Unexpected dependency ${name}`); return modules[name];
  }, module, module.exports);
  return module.exports;
}
const context = { applicationInfo: { name: 'org.example.synthetic' }, resourceManager: {
  getStringByNameSync: name => ({ new_mail_notification_title: 'New mail', new_mail_notification_text: 'Open inbox' })[name]
} };
function fixture() {
  const calls = []; let enabled = false, allow = true, works = [], rejectStart = false, cancelError = 0;
  const state = { slots: [], slotReads: 0, rejectSlot: false, details: {}, rejectDetails: false, rejectPermissionRead: false,
    badgeFailure: false, badgeGate: null, badgeNumber: 0 };
  const notificationManager = {
    SlotType: { SOCIAL_COMMUNICATION: 1 }, ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
    isNotificationEnabled: async () => { if (state.rejectPermissionRead) throw new Error(); return enabled; },
    getSlots: async () => { state.slotReads++; return state.slots; },
    getSlot: async type => state.slots.find(slot => slot.notificationType === type),
    addSlot: async type => { calls.push(['slot', type]); if (state.rejectSlot) throw new Error('Synthetic slot failure'); state.slots.push({ notificationType: type }); },
    getNotificationSetting: async () => { if (state.rejectDetails) throw new Error(); return state.details; },
    openNotificationSettings: async ctx => { calls.push(['settings', ctx]); },
    setBadgeNumber: async value => {
      calls.push(['badge', value]); if (state.badgeGate) await state.badgeGate;
      if (state.badgeFailure) throw new Error('Synthetic badge failure');
      state.badgeNumber = value;
    },
    requestEnableNotification: async ctx => { calls.push(['permission', ctx]); enabled = allow; },
    publish: async request => { calls.push(['publish', request]); },
    cancel: async id => { calls.push(['cancel', id]); if (cancelError) throw { code: cancelError }; }
  };
  const wantAgent = { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 4, CONSTANT_FLAG: 8 },
    getWantAgent: async info => { calls.push(['agent', info]); return { syntheticAgent: true }; } };
  const workScheduler = {
    NetworkType: { NETWORK_TYPE_ANY: 0 },
    obtainAllWorks: async () => works.map(work => ({ ...work })),
    startWork: work => { calls.push(['start', work]); if (rejectStart && work.repeatCycleTime === 240 * 60000) throw new Error(); works.push(work); },
    stopWork: (work, cancel) => { calls.push(['stop', work, cancel]); if (cancel) works = works.filter(value => value.workId !== work.workId); }
  };
  const { NotificationPlatform } = load('harmony/entry/src/main/ets/mail/notifications/NotificationPlatform.ets', {
    '@kit.AbilityKit': { wantAgent }, '@kit.NotificationKit': { notificationManager }, '@kit.BackgroundTasksKit': { workScheduler }
  });
  return { platform: NotificationPlatform, calls, state, workScheduler, setAllowed(value) { allow = value; },
    setEnabled(value) { enabled = value; },
    rejectReplacement() { rejectStart = true; }, cancelError(code) { cancelError = code; } };
}

test('Notification permission is requested explicitly and an existing grant is reused', async () => {
  const f = fixture(); assert.equal(await f.platform.isEnabled(), false); assert.equal(f.calls.length, 0);
  await f.platform.requestEnable(context); await f.platform.requestEnable(context);
  assert.equal(f.calls.filter(call => call[0] === 'permission').length, 1);
  const denied = fixture(); denied.setAllowed(false);
  await assert.rejects(denied.platform.requestEnable(context), /not enabled/);
});
test('Notification content is generic with an immutable opaque account route and stable social ID', async () => {
  const f = fixture(); await f.platform.publish(context, 42, 'opaque-account-id');
  const agent = f.calls.find(call => call[0] === 'agent')[1], request = f.calls.find(call => call[0] === 'publish')[1];
  assert.deepEqual(agent.wants, [{ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility', parameters: { mailNotificationAccountId: 'opaque-account-id' } }]);
  assert.equal(agent.requestCode, 42); assert.deepEqual(agent.actionFlags, [4, 8]);
  assert.deepEqual(request.content, { notificationContentType: 0, normal: { title: 'New mail', text: 'Open inbox' } });
  assert.equal(request.id, 42); assert.equal(request.notificationSlotType, 1); assert.equal(request.tapDismissed, true);
  assert.equal(request.isAlertOnce, false); assert.equal(request.badgeNumber, 0);
  assert.equal(JSON.stringify(request).includes('opaque-account-id'), false);
  await f.platform.publish(context, 42, 'opaque-account-id');
  assert.deepEqual(f.calls.filter(call => call[0] === 'publish').map(call => [call[1].id, call[1].isAlertOnce]), [[42, false], [42, false]]);
  assert.equal(f.calls.filter(call => call[0] === 'slot').length, 1);
  assert.equal(f.calls.filter(call => call[0] === 'permission').length, 0);
});
test('Creating a social slot is shared, preserves disabled slots, and retries failures', async () => {
  const f = fixture(); await Promise.all([f.platform.ensureSlot(), f.platform.ensureSlot()]);
  await f.platform.ensureSlot(); assert.equal(f.state.slotReads, 1);
  assert.deepEqual(f.calls, [['slot', 1]]);
  const existing = fixture(); existing.state.slots = [{ notificationType: 1, enabled: false }];
  await existing.platform.ensureSlot(); assert.deepEqual(existing.calls, []);
  assert.equal(existing.state.slots[0].enabled, false);
  const failed = fixture(); failed.state.rejectSlot = true;
  await assert.rejects(failed.platform.ensureSlot(), /slot failure/);
  failed.state.rejectSlot = false; await failed.platform.ensureSlot();
  assert.equal(failed.calls.filter(call => call[0] === 'slot').length, 2);
});
test('Settings distinguish disabled banners from API24 unknown fields without requesting permission', async () => {
  const f = fixture(); f.setEnabled(true);
  f.state.details = { bannerEnabled: false, badgeNumberEnabled: true };
  assert.deepEqual(await f.platform.settings(), { enabled: true, bannerEnabled: false, badgeEnabled: true, slotEnabled: undefined });
  f.state.details = { soundEnabled: true, vibrationEnabled: false };
  const older = await f.platform.settings();
  assert.equal(older.enabled, true); assert.equal(older.bannerEnabled, undefined); assert.equal(older.badgeEnabled, undefined);
  f.state.slots[0].enabled = false;
  f.state.rejectDetails = true; assert.deepEqual(await f.platform.settings(), { enabled: true, slotEnabled: false });
  f.state.rejectPermissionRead = true; assert.deepEqual(await f.platform.settings(), { enabled: false, slotEnabled: false });
  assert.deepEqual(f.calls, [['slot', 1]]);
});
test('Opening system settings creates the banner-capable slot without re-requesting permission', async () => {
  const f = fixture(); await f.platform.openSettings(context);
  assert.deepEqual(f.calls, [['slot', 1], ['settings', context]]);
  assert.equal(await f.platform.isEnabled(), false);
});
test('Unread badge sets are serialized absolute values even when local requests repeat', async () => {
  const f = fixture(); let release;
  f.state.badgeGate = new Promise(resolve => { release = resolve; });
  const pending = [8, 8, 0, 0, 23].map(value => f.platform.setUnreadBadge(value));
  await new Promise(setImmediate); assert.deepEqual(f.calls, [['badge', 8]]);
  release(); await Promise.all(pending);
  assert.deepEqual(f.calls, [['badge', 8], ['badge', 8], ['badge', 0], ['badge', 0], ['badge', 23]]);
  assert.equal(f.state.badgeNumber, 23);
});
test('Resuming can clear a badge changed by another process despite an unchanged local unread value', async () => {
  const f = fixture(); await f.platform.setUnreadBadge(0);
  // Simulate the independent WorkScheduler process publishing a later arrival.
  f.state.badgeNumber = 1;
  await f.platform.setUnreadBadge(0);
  assert.equal(f.state.badgeNumber, 0);
  assert.deepEqual(f.calls, [['badge', 0], ['badge', 0]]);
});
test('Failed badge changes retry on the next update and cannot block a later clear', async () => {
  const f = fixture(); f.state.badgeFailure = true;
  await assert.rejects(f.platform.setUnreadBadge(7), /badge failure/);
  f.state.badgeFailure = false;
  await f.platform.setUnreadBadge(7); await f.platform.setUnreadBadge(7); await f.platform.setUnreadBadge(0);
  assert.deepEqual(f.calls, [['badge', 7], ['badge', 7], ['badge', 7], ['badge', 0]]);
});
test('Scheduling keeps an unchanged persistent job and only replaces a changed interval', async () => {
  const f = fixture(); await Promise.all([f.platform.schedule(context, 120), f.platform.schedule(context, 120)]);
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0][1], { workId: 7401, bundleName: context.applicationInfo.name, abilityName: 'MailCheckAbility', isPersisted: true,
    networkType: 0, isRepeat: true, repeatCycleTime: 120 * 60000 });
  await f.platform.schedule(context, 240);
  assert.deepEqual(f.calls.map(call => call[0]), ['start', 'stop', 'start']); assert.equal(f.calls[1][2], true);
  await f.platform.schedule(context, null); await f.platform.schedule(context, null);
  assert.deepEqual(f.calls.map(call => call[0]), ['start', 'stop', 'start', 'stop']);
  await assert.rejects(f.platform.schedule(context, 5), /Invalid/);
});
test('A rejected replacement restores the prior scheduler job', async () => {
  const f = fixture(); await f.platform.schedule(context, 120); f.rejectReplacement();
  await assert.rejects(f.platform.schedule(context, 240), /could not be scheduled/);
  assert.deepEqual(f.calls.map(call => call[0]), ['start', 'stop', 'start', 'start']);
  assert.equal(f.calls[3][1].repeatCycleTime, 120 * 60000);
  await f.platform.schedule(context, 120); assert.equal(f.calls.length, 4);
});
test('Canceling an absent notification is harmless while service errors remain visible', async () => {
  const f = fixture(); await f.platform.cancel(0); assert.equal(f.calls.length, 0);
  f.cancelError(1600007); await f.platform.cancel(3);
  f.cancelError(1600003); await assert.rejects(f.platform.cancel(3), /could not be cleared/);
});
test('Work extension propagates cancellation and older completion cannot stop a new job', async () => {
  const pending = [], stopped = [];
  const { default: Extension } = load('harmony/entry/src/main/ets/abilities/MailCheckAbility.ets', {
    '@kit.BackgroundTasksKit': { WorkSchedulerExtensionAbility: class {}, workScheduler: { stopWork: (...args) => stopped.push(args) } },
    '../mail/notifications/MailNotificationService': { MailNotificationService: { run: (ctx, background, cancelled) => {
      let resolve; const promise = new Promise(done => { resolve = done; }); pending.push({ ctx, background, cancelled, resolve }); return promise;
    } } }
  });
  const ability = new Extension(); ability.context = context;
  const work = { workId: 7401 }; ability.onWorkStart(work);
  assert.equal(pending[0].background, true); assert.equal(pending[0].cancelled(), false);
  ability.onWorkStop(work); assert.equal(pending[0].cancelled(), true); ability.onWorkStart(work);
  pending[0].resolve(); await new Promise(setImmediate); assert.equal(stopped.length, 0);
  pending[1].resolve(); await new Promise(setImmediate); assert.deepEqual(stopped, [[work, false]]);
});

test('Badge totals are numeric, reject invalid values, and preserve counts above the launcher display threshold', async () => {
  const f = fixture();
  for (const value of [-1, 1.5, NaN, Infinity, true, '5']) {
    await assert.rejects(f.platform.setUnreadBadge(value), /Invalid unread count/);
  }
  assert.deepEqual(f.calls, []);
  await f.platform.setUnreadBadge(143);
  assert.equal(f.state.badgeNumber, 143);
});
