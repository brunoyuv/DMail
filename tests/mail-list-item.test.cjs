const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const row = fs.readFileSync('harmony/entry/src/main/ets/pages/MailListItem.ets', 'utf8');
const parent = fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets', 'utf8');
const measure = row.match(/  private measureHeight\([\s\S]*?\n  }/)[0];
const Item = new Function(ts.transpileModule(`class Item { ${measure} }; return Item;`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021 }
}).outputText)();

test('Measuring newly visible rows changes only their own layout state; repeated callbacks are inert', () => {
  const updates = new Map();
  const items = Array.from({ length: 2000 }, (_, index) => {
    const item = new Item(); let height = 0;
    Object.defineProperty(item, 'contentHeight', { get: () => height, set: value => {
      height = value; updates.set(index, (updates.get(index) || 0) + 1);
    } }); return item;
  });
  for (const item of items) item.measureHeight(112);
  updates.clear();
  for (let pass = 0; pass < 100; pass++) {
    for (const item of items.slice(0, 12)) item.measureHeight(112.2);
  }
  assert.equal(updates.size, 0);
  items[1000].measureHeight(96);
  assert.deepEqual([...updates], [[1000, 1]]);
  for (const value of [0, -1, NaN, Infinity]) items[1000].measureHeight(value);
  assert.equal(items[1000].contentHeight, 96); assert.equal(updates.get(1000), 1);
});

test('ArkUI row measurements are component-local and action permission remains reactive', () => {
  assert.doesNotMatch(parent, /rowContentHeights/);
  assert.match(parent, /ForEach\(this.visibleEmails\(\)/);
  assert.match(parent, /MailListItem\(\{ mail, count: this.conversationCount\(mail\)/);
  assert.match(parent, /\(mail: JmapEmail\) => this.mailRowKey\(mail\)/);
  assert.match(row, /@State private contentHeight: number/);
  assert.doesNotMatch(row, /new Map|@Prop[^\n]*mail[?:]/);
  for (const prop of ['compact', 'connected', 'readAllowed', 'starAllowed', 'archiveAllowed', 'mailAction']) {
    assert.match(row, new RegExp(`@Prop ${prop}:`));
  }
  assert.match(row, /\.onAreaChange\(\(_, area\) => \{ this.measureHeight\(Number\(area.height\)\); \}\)/);
  assert.match(row, /\.swipeAction\(/); assert.match(row, /\.enabled\(this.readAllowed\)/);
  assert.match(row, /\.enabled\(this.starAllowed\)/); assert.match(row, /\.enabled\(this.archiveAllowed\)/);
  assert.match(parent, /onOpen: \(\) => \{ if \(!this.swipeClosing\) \{ this.read\(mail\); \} \}/);
  assert.match(parent, /onReadFlag: \(\) => \{ this.rowKeyword\(mail, '\$seen'\); \}/);
});

test('Prepared row text survives repeated layout changes without reading or formatting message content', () => {
  const methods = ['aboutToAppear', 'updateDate', 'measureHeight'].map(name =>
    row.match(new RegExp(`  (?:private )?${name}\\([\\s\\S]*?\\n  }`))[0]);
  const PreparedItem = new Function(ts.transpileModule(`class Item { ${methods.join('\n')} }; return Item;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2021 }
  }).outputText)();
  let formats = 0;
  const mail = { from: [{ name: 'Sender', email: 'sender@example.test' }], preview: 'Saved\n\t preview', receivedAt: 123 };
  const item = Object.assign(new PreparedItem(), { mail, contentHeight: 0, dateLabel: value => { formats++; return 'Date ' + value; } });
  item.aboutToAppear();
  assert.equal(item.senderText, 'Sender'); assert.equal(item.previewText, 'Saved preview');
  assert.equal(item.dateText, 'Date 123'); assert.equal(formats, 1);
  for (const field of ['from', 'preview', 'htmlBody', 'textBody']) {
    Object.defineProperty(mail, field, { get() { throw new Error('Layout must not read ' + field); } });
  }
  for (let i = 0; i < 100; i++) item.measureHeight(i % 2 ? 96 : 112);
  assert.equal(formats, 1);
  item.updateDate(); assert.equal(formats, 2, 'Explicit language change may reformat the date only');
  const render = row.slice(row.indexOf('  @Builder'));
  assert.doesNotMatch(render, /\.map\(|\.replace\(|dateLabel\(/);
  assert.match(render, /Text\(this.senderText\)/); assert.match(render, /Text\(this.previewText\)/);
});
