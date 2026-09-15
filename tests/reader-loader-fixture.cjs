const assert = require('node:assert/strict');

// UI tests control the loader boundary. Cache, network, preparation and durable
// picture semantics are tested against the real loader in its dedicated suite.
// This adapter retains the older UI fixtures' controlled cache/document awaits.
class MailMessageLoadCancelled extends Error {}
class AutomaticMailWorkCancelled extends Error {}
const automatic = state => ({
  async run(operation, active) {
    if (!active()) throw new AutomaticMailWorkCancelled();
    state.automaticStarts = (state.automaticStarts || 0) + 1;
    return operation();
  },
  cancelInactive() {}
});
function bindReaderLoader(ui, state, stableMessageKey) {
  state.loaderCalls ||= [];
  ui.messageLoader = {
    async open(client, account, header, show, hide, active) {
      state.loaderCalls.push({ account, id: header.id, show, hide });
      if (state.loadMessage) return state.loadMessage(client, account, header, active);
      const cached = await ui.accountStore.mail.email(account.id, header.id, true);
      if (!active()) throw new MailMessageLoadCancelled();
      let mail = cached?.bodySavedAt != null ? cached.mail : null;
      if (!mail) {
        mail = await client.readEmail(account.serverId, header.id);
        if (!active()) throw new MailMessageLoadCancelled();
        if (!mail) throw Object.assign(new Error('Synthetic body unavailable'), { code: 'network' });
        await ui.accountStore.mail.saveEmail?.(account.id, mail);
      }
      const record = await ui.accountStore.documents.read(account.id, stableMessageKey(mail));
      if (!active()) throw new MailMessageLoadCancelled();
      assert.ok(mail, 'Controlled loader returns a body or a failure');
      return { mail, document: record?.document || null };
    },
    cancel() { state.loaderCancels = (state.loaderCancels || 0) + 1; },
    whenIdle: async () => {}
  };
}
function actualLoaderFixture(options) {
  const fs = require('node:fs'), path = require('node:path');
  const { createRequire } = require('node:module');
  const filename = path.resolve('tests/mail-message-loader.test.cjs'), source = fs.readFileSync(filename, 'utf8');
  const boundary = source.indexOf('\ntest('); assert.ok(boundary > 0);
  const setup = new Function('require', source.slice(0, boundary) + '\nreturn { fixture, mail };')(createRequire(filename));
  return { ...setup.fixture(options), mail: setup.mail };
}
module.exports = { bindReaderLoader, MailMessageLoadCancelled, AutomaticMailWorkCancelled, automatic, actualLoaderFixture };
