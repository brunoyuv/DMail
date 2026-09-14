const { test } = require('node:test');
const assert = require('node:assert/strict');
const { hasRemotePictures, htmlContentInset, mailDocument, foldMailQuotes, plainTextMailHtml } = require('../.tools/test-output/mail/html/HtmlDocument.js');

test('Remote pictures include background attributes, CSS URLs and later srcset candidates', () => {
  for (const html of [
    '<img src="https://pictures.example.test/photo.jpg">',
    '<table background="//pictures.example.test/background.png">',
    '<body background=http://pictures.example.test/background.png>',
    '<div style="background-image: url(\'https://pictures.example.test/a.png\')">',
    '<source srcset="cid:small 1x, https://pictures.example.test/large.png 2x">',
    '<img srcset="data:image/png;base64,AA== 1x, //pictures.example.test/large.png 2x">'
  ]) { assert.equal(hasRemotePictures(html), true, html); }
});

test('HTML encoded image references still offer Load pictures', () => {
  for (const html of [
    '<img src="&#104;ttps&#58;&#47;&#47;pictures.example.test/a.png">',
    '<img src="&#x68;ttps&colon;&sol;&sol;pictures.example.test/a.png">',
    '<td background="&#47;&#47;pictures.example.test/a.png">',
    '<img srcset="cid:small 1x,&#32;https://pictures.example.test/a.png 2x">'
  ]) { assert.equal(hasRemotePictures(html), true, html); }
});

test('Inline images and normal links do not offer unnecessary network consent', () => {
  for (const html of [
    '<img src="cid:logo@example.test">', '<img src="data:image/png;base64,AA==">',
    '<img srcset="cid:small 1x, cid:large 2x">', '<a href="https://example.test">Read online</a>',
    '<p>https://example.test is a website</p>', '<script src="https://example.test/script.js"></script>',
    '<link rel="stylesheet" href="https://example.test/theme.css">'
  ]) { assert.equal(hasRemotePictures(html), false, html); }
});

test('Picture permission changes only the image CSP and preserves inline CID data', () => {
  const source = '<img src="data:image/png;base64,AA=="><script>alert(1)</script><form action="https://example.test"></form>';
  const blocked = mailDocument(source, false), allowed = mailDocument(source, true);
  assert.equal(allowed.replace('img-src data: https: http:', 'img-src data:'), blocked);
  for (const document of [blocked, allowed]) {
    assert.match(document, /^<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy"/);
    for (const directive of ['default-src', 'script-src', 'base-uri', 'form-action', 'frame-src', 'object-src', 'media-src']) {
      assert.ok(document.includes(`${directive} 'none'`));
    }
    assert.ok(document.includes(source));
  }
});

test('Decoded Unicode has one UTF-8 declaration before any sender content', () => {
  const text = '中文 日本語 café Grüße 😀 e\u0301';
  const source = `<meta charset="windows-1252"><meta http-equiv="Content-Type" content="text/html; charset=gbk"><p>${text} &amp; &#x4E2D;</p>`;
  const document = mailDocument(source, false);
  assert.equal((document.match(/charset=/g) || []).length, 1);
  assert.ok(document.indexOf('<meta charset="utf-8">') < 1024);
  assert.ok(document.includes(`<p>${text} &amp; &#x4E2D;</p>`));
  assert.ok(!document.includes('windows-1252'));
});

test('Provider viewport and refresh metadata cannot replace the local document configuration', () => {
  const source = '<html><head><meta name="viewport" content="width=980"><meta http-equiv="refresh" content="0; url=https://example.test?a=>"><style>body{color:#224466;background:#ffeedd}</style></head><body dir="rtl"><p>中文 日本語</p></body></html>';
  const document = mailDocument(source, false);
  assert.equal((document.match(/name="viewport"/g) || []).length, 1);
  assert.ok(!document.includes('http-equiv="refresh"'));
  assert.ok(document.includes('<style>body{color:#224466;background:#ffeedd}</style>'));
  assert.ok(document.includes('<body dir="rtl"><p>中文 日本語</p>'));
});

test('Wide tables fit the viewport while small signatures and unequal column widths stay distinct', () => {
  const source = '<table width="900" style="width:900px;min-width:900px;background:#145cb3"><tr><td width="700">Main</td><td width="200">Side</td></tr></table><table width="180"><tr><td>Signature</td></tr></table>';
  const document = mailDocument(source, false);
  assert.ok(document.includes('width:min(100%,900px)!important'));
  assert.ok(document.includes('width:min(100%,180px)!important'));
  assert.ok(document.includes('<td width="700">Main</td><td width="200">Side</td>'));
  assert.ok(document.includes('background:#145cb3'));
  assert.ok(!document.includes('table-layout:fixed'));
});

test('CSS widths override legacy table attributes and existing responsive widths are retained', () => {
  const source = '<table width="900" style=width:180px><tr><td>A</td></tr></table><table width="900" style="width:75%;color:blue"><tr><td>B</td></tr></table><table title="x > y" width=240><tr><td>C</td></tr></table>';
  const document = mailDocument(source, false);
  assert.ok(document.includes("style='width:180px;width:min(100%,180px)!important'"));
  assert.ok(document.includes('<table width="900" style="width:75%;color:blue">'));
  assert.ok(document.includes('<table title="x > y" width=240 style="width:min(100%,240px)!important">'));
});

test('Table width adaptation respects CSS declaration order, importance and original attribute quoting', () => {
  const source = `<table width="900" style="min-width:900px"><tr><td>A</td></tr></table><table style='background:url("cid:logo");width:800px;width:240px'><tr><td>B</td></tr></table><table style="width:180px!important;width:900px"><tr><td>C</td></tr></table>`;
  const document = mailDocument(source, false);
  assert.ok(document.includes('min-width:900px;width:min(100%,900px)!important'));
  assert.ok(document.includes(`style='background:url("cid:logo");width:800px;width:240px;width:min(100%,240px)!important'`));
  assert.ok(document.includes('width:180px!important;width:900px;width:min(100%,180px)!important'));
});

test('Reader and composer gutters are bounded and nonfinite layout values use the default', () => {
  assert.equal(htmlContentInset(16), 16); assert.equal(htmlContentInset(0), 0);
  assert.equal(htmlContentInset(-10), 0); assert.equal(htmlContentInset(200), 40);
  assert.equal(htmlContentInset(NaN), 20);
  assert.ok(mailDocument('<p>Body</p>', false, 16).includes('margin:0 16px 16px!important'));
  assert.ok(mailDocument('<p>Body</p>', false, 0).includes('margin:0 0px 0px!important'));
});

test('Explicit HTML history starts folded and preserves authored text before, between and after quotes', () => {
  const source = '<p>My first answer.</p><blockquote cite="mid:one"><p>Earlier question.</p></blockquote><p>My inline answer.</p><blockquote>Another question.</blockquote><p>My final answer.</p>';
  const html = foldMailQuotes(source);
  assert.equal((html.match(/<details class="tb-mail-quote">/g) || []).length, 2);
  assert.equal((html.match(/<details[^>]*\bopen\b/g) || []).length, 0);
  assert.match(html, /^<p>My first answer\.<\/p><details/);
  assert.match(html, /<\/blockquote><\/details><p>My inline answer\.<\/p><details/);
  assert.match(html, /<\/blockquote><\/details><p>My final answer\.<\/p>$/);
  assert.ok(html.includes('<blockquote cite="mid:one" data-tb-quote-level="1"><p>Earlier question.</p></blockquote>'));
  assert.equal(foldMailQuotes('<blockquote>One</blockquote><blockquote>Two</blockquote>').includes('</details><details'), true);
});

test('Provider wrappers fold attribution with history, preserve CID/UTF-8, and color nested quote levels', () => {
  for (const provider of ['gmail_quote', 'yahoo_quoted', 'protonmail_quote']) {
    const source = `<p>Thanks, café 中文 😀</p><div class="other ${provider}" title="x > y"><p>On Monday, Alice wrote:</p><blockquote><div>Previous reply<img src="data:image/png;base64,AA=="></div><blockquote>Older<blockquote>Oldest</blockquote></blockquote></blockquote></div><div>Current signature</div>`;
    const html = foldMailQuotes(source);
    assert.equal((html.match(/<details /g) || []).length, 1);
    assert.ok(html.includes(`<div class="other ${provider}" title="x > y" data-tb-quote-level="1">`));
    assert.ok(html.includes('<blockquote data-tb-quote-level="1"><div>Previous reply'));
    assert.ok(html.includes('<blockquote data-tb-quote-level="2">Older<blockquote data-tb-quote-level="3">Oldest'));
    assert.match(html, /<\/div><\/details><div>Current signature<\/div>$/);
    assert.ok(html.includes('<p>Thanks, café 中文 😀</p>'));
    assert.ok(html.includes('<img src="data:image/png;base64,AA==">'));
  }
});

test('Quoted-looking prose, source samples and incomplete wrappers cannot hide authored content', () => {
  for (const source of [
    '<p>On Monday, Alice wrote:</p><p>This is my new message.</p>',
    '<div class="gmail_quote_extra">Authored content</div>',
    '<div title="Example class=\'gmail_quote\'" class="authored">Authored content</div>',
    '<div id="divRplyFwdMsg">From: Alice</div><p>Authored reply</p>',
    '<!-- <blockquote>Not a quote</blockquote> --><p>Visible</p>',
    '<style>.x:before{content:"<blockquote>Example</blockquote>"}</style><p>Visible</p>',
    '<script>const example="<blockquote>Example</blockquote>";</script><p>Visible</p>',
    '<pre>&lt;blockquote&gt;Example&lt;/blockquote&gt;</pre>',
    '<blockquote><p>Unmatched quoted tag</p><p>Authored content must not disappear.</p>',
    '<div class="gmail_quote"><p>Unmatched quote wrapper</p>'
  ]) { assert.equal(foldMailQuotes(source), source); }
});

test('Optional paragraph closes within HTML quotes do not swallow the following authored answer', () => {
  const html = foldMailQuotes('<blockquote><p>Question without closing paragraph</blockquote><p>My answer</p>');
  assert.match(html, /Question without closing paragraph<\/blockquote><\/details><p>My answer<\/p>$/);
});

test('Text-only mail escapes markup, keeps authored lines visible, and folds explicit quote runs', () => {
  const text = 'My <answer> & café 中文 😀\r\n\r\n> Earlier <script>alert(1)</script>\r\n>> Older reply\r\n> More history\r\nMy inline reply\r\n> Another question\r\n\r\nSignature';
  const source = plainTextMailHtml(text);
  assert.ok(source.startsWith('<div class="tb-plain-text">My &lt;answer&gt; &amp; café 中文 😀\n\n'));
  assert.ok(source.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
  assert.ok(!source.includes('<script>'));
  const html = foldMailQuotes(source);
  assert.equal((html.match(/<details /g) || []).length, 2);
  assert.ok(html.includes('<blockquote data-tb-quote-level="2">Older reply\n</blockquote>More history'));
  assert.ok(html.includes('</blockquote></details>My inline reply\n<details'));
  assert.ok(html.endsWith('</blockquote></details>\nSignature</div>'));
  assert.equal(hasRemotePictures(plainTextMailHtml('> <img src="https://example.test/tracker">')), false);
});

test('Quote disclosure is localized, script-free and retains the existing remote image policy', () => {
  const source = '<blockquote><img src="https://example.test/picture">History</blockquote>';
  const html = mailDocument(source, false, 16, '显示 <引用>', '隐藏 & 引用');
  assert.ok(html.includes('显示 &lt;引用&gt;'));
  assert.ok(html.includes('隐藏 &amp; 引用'));
  assert.ok(html.includes("script-src 'none'"));
  assert.ok(html.includes("img-src data:;"));
  assert.ok(!html.includes('onclick='));
  assert.ok(html.includes('.tb-mail-quote[open]>summary .tb-quote-hide{display:inline!important}'));
  for (const color of ['#3474ad', '#3d8062', '#8655a0']) { assert.ok(html.includes(color)); }
  assert.equal(mailDocument(source, true).replace('img-src data: https: http:', 'img-src data:'), mailDocument(source, false));
});

test('Dark quote styling retains authored HTML and original picture colors for native adaptation', () => {
  const image = '<img src="data:image/png;base64,AA==" style="background:#fff" alt="Original picture">';
  const source = `<table bgcolor="#ffffff" style="background:white;color:black"><tr><td>Current reply 中文</td></tr></table><blockquote style="background:#fff;color:#000">Older reply<blockquote>Earlier reply${image}</blockquote></blockquote>`;
  const document = mailDocument(source, false);
  assert.ok(document.includes('<table bgcolor="#ffffff" style="background:white;color:black">'));
  assert.ok(document.includes(image));
  assert.ok(document.includes('Current reply 中文'));
  assert.ok(document.includes('@media(prefers-color-scheme:dark){'));
  for (const color of ['#82b6eb', '#80c5a3', '#bf9add']) { assert.ok(document.includes(color)); }
  // Native forced dark mode must remain available for the sender's white
  // tables; a global dark color-scheme would incorrectly opt that HTML out.
  assert.ok(!/(?:^|[;{])\s*color-scheme\s*:/i.test(document));
  assert.ok(!/filter\s*:\s*[^;}]*(?:invert|hue-rotate)/i.test(document));
  assert.ok(document.includes("img-src data:;"));
  assert.ok(document.includes("script-src 'none'"));
  assert.ok(document.includes('<details class="tb-mail-quote"><summary>'));
});
