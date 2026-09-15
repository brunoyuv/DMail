const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const source = fs.readFileSync('harmony/entry/src/main/ets/mail/MessagePreview.ts', 'utf8');
function load(text) {
  const module = { exports: {} };
  new Function('module', 'exports', ts.transpileModule(text, { compilerOptions: {
    target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS
  } }).outputText)(module, module.exports);
  return module.exports.messagePreview;
}
const messagePreview = load(source);
// The old expressions are exercised only on small differential fixtures.
const previous = load(source.replace('stripTags(omitNonContent(source))', `source
  .replace(/<(head|style|script|template)\\b[^>]*>[\\s\\S]*?(?:<\\/\\1\\s*>|$)/gi, ' ')
  .replace(/<[^>]*>/g, ' ')`));
const mail = html => ({ preview: '', textBody: null, htmlBody: html });

test('HTML excerpts preserve content suppression, entities, unmatched markup and Unicode', () => {
  const samples = ['', '<', '<<', 'a < 3 > b', 'text<missing', '<title>Title</title>Body',
    '<head><title>Hidden</title><style>p{color:red}</style></head><p>Visible</p>',
    '<HEAD lang="en">Hidden</HEAD   ><p>Visible</p>', '<style>hidden without close',
    '<script>x</script><template>hidden</template>Shown', 'before<!-- hidden -->after',
    '<p title=">">Quoted</p>', '<textarea><p>Text</p></textarea>',
    '中文 café 😀 &amp; &#x1f600; &lt;ok&gt; &nbsp; &#0; &#xD800;',
    '<head-word>previous behavior</head>visible', '<head中文>previous behavior</head>visible',
    '<\u0301p>Unicode</p>', 'İ outside <STYLE>hidden</STYLE> visible',
    '   <p>First</p>\r\n\t<div>Second 👩🏽‍💻</div>'];
  for (const html of samples) assert.equal(messagePreview(mail(html)), previous(mail(html)), html);
  assert.equal(messagePreview(mail('<head><title>Hidden</title></head><p>Visible</p>')), 'Visible');
  assert.equal(messagePreview(mail('<script>x</script><template>hidden</template>Shown')), 'Shown');
});

test('Small mixed malformed excerpts remain equivalent to the previous pipeline', () => {
  const tokens = ['<', '>', '<head', '<style>', '<script', '<template>', '</head>', '</style>',
    '</script >', '</template>', 'a', ' ', '\n', '\t', '<!--', '-->', '"', "'", '中文', '😀', '&amp;'];
  let seed = 0xD_A11;
  for (let fixture = 0; fixture < 1000; fixture++) {
    let html = '';
    for (let i = 0; i < 35; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      html += tokens[seed % tokens.length];
    }
    assert.equal(messagePreview(mail(html)), previous(mail(html)), html);
  }
});

test('Large unfinished ordinary and non-content tags are scanned without suffix retries', () => {
  for (const fragment of ['<a ', '<head ', '<script ', '<template ']) {
    const html = 'Start 中文 ' + fragment.repeat(20_000);
    assert.equal(messagePreview(mail(html)), Array.from(html.replace(/\s+/g, ' ').trim()).slice(0, 180).join(''));
    assert.equal(messagePreview(mail(html + '>ignored</head>Tail')).startsWith('Start 中文'), true);
  }
});

test('Excerpt input bounds, supplied previews and plain-text preference stay unchanged', () => {
  assert.equal(messagePreview(mail(' '.repeat(200000) + '<p>Outside budget</p>')), '');
  assert.equal(messagePreview(mail('😀'.repeat(300))), '😀'.repeat(180));
  assert.equal(messagePreview({ preview: '  Supplied\nsummary ', textBody: 'Plain', htmlBody: '<p>HTML</p>' }), 'Supplied summary');
  assert.equal(messagePreview({ preview: '', textBody: '  Plain\n中文 ', htmlBody: '<p>HTML</p>' }), 'Plain 中文');
});
