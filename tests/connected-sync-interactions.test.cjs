const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');

// Use actual component methods and native callback bodies. Download-on-open
// has no bulk worker; these checks retain the hidden-gesture/header protections.
function setup(file, names) {
  const filename = path.resolve(file), source = fs.readFileSync(filename, 'utf8');
  const boundary = source.indexOf('\ntest('); assert.ok(boundary > 0);
  return new Function('require', source.slice(0, boundary) + '\nreturn {' + names + '};')(createRequire(filename));
}
const inbox = setup('tests/connected-inbox-updates.test.cjs', 'fixture,mail,page,source,method,ts,options');
const back = new Function('AutomaticMailWork', inbox.ts.transpileModule('class Host {' + inbox.method('back') + '}',
  { compilerOptions: inbox.options }).outputText + ';return Host.prototype.back;')({ cancelInactive() {} });
function callback(pattern, args, state) {
  const found = pattern.exec(inbox.source); assert.ok(found, String(pattern));
  return new Function('MailInboxUpdates', 'ScrollState', 'AutomaticMailWork', `return function(${args}) {${found[1]}};`)(
    { isForeground: () => state.foreground }, { Scroll: 'Scroll' }, { cancelInactive() {} });
}
function fixture() {
  const f = inbox.fixture(), ui = f.ui;
  ui.back = back; ui.openInboxOnLaunch = true;
  f.state.nextPage = async () => inbox.page([inbox.mail('old', false)]);
  const native = {
    scroll: callback(/\.onScrollFrameBegin\(\(offset: number, state: ScrollState\) => \{([\s\S]*?)\n            \}\)/, 'offset,state', f.state),
    stop: callback(/\.onScrollStop\(\(\) => \{ (this\.inboxScrollActive[\s\S]*?) \}\)/, '', f.state),
    navBar: callback(/\.onNavBarStateChange\(\(visible: boolean\) => \{([\s\S]*?)\}\)/, 'visible', f.state),
    readerStart: callback(/\.onScrollStart\(\(\) => \{([\s\S]*?)\n          \}\)/, '', f.state),
    pull: callback(/\.pullToRefresh\(this\.client !== null\)\s*\.onOffsetChange\(\(offset: number\) => \{([\s\S]*?)\n          \}\)/, 'offset', f.state)
  };
  return { ...f, native };
}

test('Interrupted Inbox scroll can open/back, refresh and reopen without a stop callback or bulk downloads', async () => {
  const { ui, state, native } = fixture();
  native.scroll.call(ui, 20, 'Scroll'); assert.equal(ui.inboxScrollActive, true);
  await ui.read(ui.emails[0]); assert.equal(ui.bodyLoaded, true);
  native.navBar.call(ui, false); ui.readerVisibilityChanged(true);
  assert.equal(ui.inboxScrollActive, false);
  ui.back(); state.paths.pop(); ui.readerVisibilityChanged(false); native.navBar.call(ui, true);
  await ui.refreshMailbox(); await ui.read(ui.emails[0]);
  assert.equal(state.calls.length, 1); assert.equal(ui.bodyLoaded, true);
  assert.equal(ui.selected.textBody, 'Cached body old'); assert.equal(state.bodyCalls.length, 0);
  assert.equal(state.loaderCalls.length, 2, 'Only explicit message openings enter the loader');
});

test('A tablet list that stays visible retains its genuine gesture gate until its native stop', async () => {
  const { ui, state, versions, account, timers, fire, native } = fixture();
  ui.tablet = true; native.scroll.call(ui, 20, 'Scroll');
  native.navBar.call(ui, true); ui.readerVisibilityChanged(true);
  versions.set(account.id, 1);
  for (let i = 0; i < 5; i++) ui.inboxChanged();
  assert.equal(timers.size, 0); assert.equal(state.calls.length, 0); assert.equal(ui.inboxScrollActive, true);
  native.stop.call(ui); await fire();
  assert.equal(state.calls.length, 1); assert.equal(ui.inboxScrollActive, false);
  assert.equal(state.loaderCalls.length, 0); assert.equal(state.bodyCalls.length, 0);
  assert.match(inbox.source, /\.mode\(this\.openInboxOnLaunch \? NavigationMode\.Auto : NavigationMode\.Stack\)/);
});

test('Backgrounding retires interrupted pull/reader gestures once and ignores late hidden callbacks', async () => {
  const { ui, state, native } = fixture();
  ui.inboxChanged(); ui.readerVisibilityChanged(true); native.pull.call(ui, 40); native.readerStart.call(ui);
  let panelsClosed = 0, submitted = 0;
  ui.inboxSwipes.add('a:pending'); ui.mailScroller.closeAllSwipeActions = () => panelsClosed++;
  ui.pendingSwipeAction = () => { ui.pendingSwipeAction = null; submitted++; };
  state.foreground = false; ui.inboxChanged();
  assert.equal(ui.inboxPullActive, false); assert.equal(ui.readerScrollActive, false); assert.equal(ui.inboxSwipes.size, 0);
  assert.equal(panelsClosed, 1); assert.equal(submitted, 1);
  native.scroll.call(ui, 20, 'Scroll'); native.pull.call(ui, 40); native.readerStart.call(ui); ui.inboxChanged();
  assert.equal(ui.inboxScrollActive, false); assert.equal(ui.inboxPullActive, false); assert.equal(ui.readerScrollActive, false);
  assert.equal(panelsClosed, 1); assert.equal(state.bodyCalls.length, 0);
  state.foreground = true; ui.inboxChanged();
  assert.equal(state.loaderCalls.length, 0); assert.equal(state.bodyCalls.length, 0); assert.equal(submitted, 1);
});

test('Retiring only the reader does not release an independent split-view Inbox scroll', () => {
  const { ui, state, native } = fixture();
  native.scroll.call(ui, 20, 'Scroll'); ui.readerVisibilityChanged(true); native.readerStart.call(ui);
  ui.readerVisibilityChanged(false);
  assert.equal(ui.readerScrollActive, false); assert.equal(ui.inboxScrollActive, true);
  ui.inboxVisibilityChanged(false); assert.equal(ui.inboxScrollActive, false);
  assert.equal(state.loaderCalls.length, 0); assert.equal(state.bodyCalls.length, 0);
  assert.match(inbox.source, /\.onHidden\(\(\) => this\.inboxVisibilityChanged\(false\)\)/);
  assert.match(inbox.source, /\.onHidden\(\(\) => this\.readerVisibilityChanged\(false\)\)/);
});
