const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { mailHtmlTokens } = require('../.tools/test-output/mail/html/HtmlTokens.js');
const { prepareMailHtml, hasRemotePictures } = require('../.tools/test-output/mail/html/HtmlDocument.js');

test('Source spans agree with the previous scanner on complete authored tags and raw blocks', () => {
  // The former browser-link scanner is used only on small, complete fixtures.
  const previous = /<!--[\s\S]*?(?:-->|$)|<(script|style|textarea|title)\b(?:"[^"]*"|'[^']*'|[^'">])*?>[\s\S]*?(?:<\/\1\s*>|$)|<[a-z][a-z0-9:-]*\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi;
  const fixtures = [
    '<p>café 中文 😀</p><a href="https://example.test?a=>b&amp;q=1" target="_blank">Read</a>',
    `<img src='https://example.test/p.png' style='background:url("x;y>z");width:240px' width=240>`,
    '<table width="800"><tr><td><a href=#part>Jump</a></td></tr></table>',
    '<!-- <img src="https://example.test/not-a-picture"> --><p title="Example <img>">Text</p>',
    '<script>let html="<img src=example>";</script><style>.x{content:"<a>"}</style>',
    '<textarea><img src="https://example.test/sample"></textarea><title>Literal <b> text</title>'
  ];
  for (let round = 0; round < 64; round++) {
    const source = fixtures.slice(round % fixtures.length).concat(fixtures.slice(0, round % fixtures.length)).join(` prose ${round} `);
    const expected = Array.from(source.matchAll(previous), match => ({ start: match.index, end: match.index + match[0].length, text: match[0] }));
    const actual = mailHtmlTokens(source).filter(token => !token.closing).map(token => ({
      start: token.start, end: token.end, text: source.slice(token.start, token.end)
    }));
    assert.deepEqual(actual, expected);
  }
});

test('Raw-text examples remain verbatim and cannot create picture controls or rewritten links', () => {
  const contents = '<a href="https://example.test" target="_blank">Example</a>' +
    '<meta charset="latin1"><table width="900"><img src="https://example.test/photo.png"></table>';
  for (const name of ['script', 'style', 'textarea', 'title', 'xmp', 'iframe', 'noembed', 'noframes', 'plaintext']) {
    const source = `<${name}>${contents}</${name}>`;
    assert.equal(prepareMailHtml(source), source, name);
    assert.equal(hasRemotePictures(source), false, name);
  }
  assert.equal(hasRemotePictures('<style>.x{background:url(https://example.test/background.png)}</style>'), true);
  assert.equal(hasRemotePictures('<style>.x{background:url(https://example.test/background.png)}'), true);
});

test('Unclosed tag or quoted suffix stays unchanged instead of finding apparent tags inside it', () => {
  for (const suffix of [
    '<a '.repeat(100),
    '<a title="unterminated <a href=https://example.test target=_blank>Example</a>',
    '<img title=\'unterminated <img src="https://example.test/photo.png">',
    '<!-- unfinished <img src="https://example.test/photo.png">'
  ]) {
    const source = '<p>Visible prefix</p>' + suffix;
    assert.equal(prepareMailHtml(source), source);
    assert.equal(hasRemotePictures(source), false);
  }
});

test('Large unfinished markup completes within a bounded VM deadline and preserves its source', () => {
  // Old quote-aware global regexes rescan each unfinished '<a' suffix. The
  // deadline is deliberately loose for CI but prevents a regression hanging it.
  vm.runInNewContext(`
    for (const token of ['<a ', '<a title="', '<table ', '<meta ', '<style ', '<script ']) {
      const source = '<p>Saved prefix</p>' + token.repeat(40000);
      assert.equal(prepareMailHtml(source), source);
      assert.equal(hasRemotePictures(source), false);
    }
  `, { assert, prepareMailHtml, hasRemotePictures }, { timeout: 2000 });
});

test('Unknown element names cannot masquerade as raw text, links or raw closing tags', () => {
  for (const suffix of ['_custom', '.custom', '中文']) {
    const img = '<img src="https://example.test/photo.png">';
    const source = `<script${suffix}>${img}</script${suffix}><a${suffix} target="_blank">Text</a${suffix}>`;
    assert.equal(prepareMailHtml(source), source);
    assert.equal(hasRemotePictures(source), true);
    const raw = `<style>example </style${suffix}>${img}</style>`;
    assert.equal(prepareMailHtml(raw), raw);
    assert.equal(hasRemotePictures(raw), false);
  }
});

test('Complete tags and CSS with long whitespace do not restart failed matches', () => {
  vm.runInNewContext(`
    const spaces = ' '.repeat(200000);
    const sources = [
      '<div ' + spaces + '></div>',
      '<img src="https://example.test/photo.png" ' + spaces + '>',
      '<a ' + spaces + '>',
      '<style>p{background:url(' + spaces + 'x)}</style>',
      '<img src="https://example.test/photo.png" style="width:1px ' + spaces + 'x;height:1px">',
      '<img src="https://example.test/photo.png" style="width:1px ' + spaces + ';height:1px">'
    ];
    for (const source of sources) { prepareMailHtml(source); hasRemotePictures(source); }
  `, { prepareMailHtml, hasRemotePictures }, { timeout: 2000 });
});
