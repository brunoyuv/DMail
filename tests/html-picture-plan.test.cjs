const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { prepareStaticMailHtml } = require('../.tools/test-output/mail/html/HtmlPicturePlan.js');

test('Static picture IDs deduplicate equivalent authorities and decoded attribute URLs', () => {
  const source = '<img src="HTTPS://Images.Example.test:443/p.png?a=1&amp;b=2#first">' +
    '<img src="//images.example.test/p.png?a=1&#38;b=2#second">' +
    '<svg><image xlink:href="https&#x3a;//images.example.test/p.png?a=1&amp;b=2"/></svg>' +
    '<a href="https://images.example.test/p.png?a=1&amp;b=2">Open the original</a>';
  const plan = prepareStaticMailHtml(source);
  assert.deepEqual(plan.pictures, [{ id: 'https://mail.invalid/picture/0', url: 'https://images.example.test/p.png?a=1&b=2' }]);
  assert.match(plan.html, /src="https:\/\/mail\.invalid\/picture\/0#first"/);
  assert.match(plan.html, /src="https:\/\/mail\.invalid\/picture\/0#second"/);
  assert.match(plan.html, /xlink:href="https:\/\/mail\.invalid\/picture\/0"/);
  assert.match(plan.html, /href="https:\/\/images\.example\.test\/p\.png\?a=1&amp;b=2" target="_self"/);
  assert.equal(plan.overflow, false);
});

test('Signed paths, query ordering, escaped slashes and repeated slashes remain exact', () => {
  const urls = ['https://images.example.test//a/../b%2fc.png?b=2&a=1&sig=A+B%2f',
    'https://images.example.test//a/../b%2Fc.png?a=1&b=2&sig=A%2BB%2F'];
  const plan = prepareStaticMailHtml(urls.map(url => `<img src="${url.replace(/&/g, '&amp;')}">`).join(''));
  assert.deepEqual(plan.pictures.map(picture => picture.url), urls);
  const root = prepareStaticMailHtml('<img src="HTTP://EXAMPLE.test:80"><img src="http://example.test/">');
  assert.deepEqual(root.pictures, [{ id: 'https://mail.invalid/picture/0', url: 'http://example.test/' }]);
});

test('Named Unicode entities, multi-code-point references and numeric C1 values decode as HTML attributes', () => {
  const plan = prepareStaticMailHtml('<img src="https://images.example.test/caf&eacute;-&NotEqualTilde;-&#128;.png?a=1&copy;=2">' +
    '<img src="https://images.example.test/&eacute.png?x=1&amp=unchanged&unknown;=yes">' +
    '<img src="https://images.example.test/&sol/no-semicolon.png">');
  assert.deepEqual(plan.pictures.map(picture => picture.url), [
    'https://images.example.test/caf%C3%A9-%E2%89%82%CC%B8-%E2%82%AC.png?a=1%C2%A9=2',
    'https://images.example.test/%C3%A9.png?x=1&amp=unchanged&unknown;=yes',
    'https://images.example.test/&sol/no-semicolon.png'
  ]);
});

test('Unicode picture URLs reuse browser-encoded cache keys without double encoding', () => {
  const plan = prepareStaticMailHtml('<img src="https://images.example.test/照片😀.png?name=café">' +
    '<img src="https://images.example.test/%E7%85%A7%E7%89%87%F0%9F%98%80.png?name=caf%C3%A9">' +
    '<img src="https://images.example.test/\ud800.png">');
  assert.deepEqual(plan.pictures.map(picture => picture.url), [
    'https://images.example.test/%E7%85%A7%E7%89%87%F0%9F%98%80.png?name=caf%C3%A9',
    'https://images.example.test/%EF%BF%BD.png'
  ]);
  const oversized = prepareStaticMailHtml(`<img src="https://images.example.test/${'é'.repeat(2000)}.png">`);
  assert.equal(oversized.pictures.length, 0);
  assert.equal(oversized.overflow, true);
});

test('Srcset preserves data and CID candidates, descriptors and authored spacing', () => {
  const plan = prepareStaticMailHtml('<picture><source srcset="cid:small 1x, //images.example.test/large.png 2x">' +
    '<img src="cid:fallback" srcset="data:image/png;base64,AAAA 1x,  https://images.example.test/photo.png?a=1&amp;b=2 2x, https://images.example.test/wide.png 1200w"></picture>');
  assert.deepEqual(plan.pictures.map(picture => picture.url), ['https://images.example.test/large.png',
    'https://images.example.test/photo.png?a=1&b=2', 'https://images.example.test/wide.png']);
  assert.match(plan.html, /src="cid:fallback"/);
  assert.match(plan.html, /srcset="cid:small 1x, https:\/\/mail\.invalid\/picture\/0 2x"/);
  assert.match(plan.html, /data:image\/png;base64,AAAA 1x,  https:\/\/mail\.invalid\/picture\/1 2x, https:\/\/mail\.invalid\/picture\/2 1200w/);
});

test('HTML backgrounds, inline CSS, style URL and image-set strings produce only image resources', () => {
  const style = '<style>@import url("https://assets.example.test/import.css");' +
    '@font-face{font-family:mail;src:url(https://assets.example.test/font.woff2)}' +
    '@media (min-width: 1px){.mail { background-image: image-set( "https://images.example.test/a.png" 1x, url(//images.example.test/b.png) 2x type("image/png") );' +
    'border-image: -webkit-image-set(\'https://images.example.test/c.png\' 1x, "https://images.example.test/d.png" 2x);' +
    'content:"url(https://assets.example.test/example.png)";}}</style>';
  const plan = prepareStaticMailHtml(style + '<body background="https://images.example.test/body.png"><table><tr>' +
    '<td background="https://images.example.test/cell.png"><div style="background: url(&quot;https://images.example.test/inline.png?a=1&amp;b=2&quot;); color: red">Hello</div></td></tr></table></body>');
  assert.deepEqual(plan.pictures.map(picture => picture.url), ['https://images.example.test/a.png', 'https://images.example.test/b.png',
    'https://images.example.test/c.png', 'https://images.example.test/d.png', 'https://images.example.test/body.png',
    'https://images.example.test/cell.png', 'https://images.example.test/inline.png?a=1&b=2']);
  assert.match(plan.html, /@import url\("https:\/\/assets\.example\.test\/import\.css"\)/);
  assert.match(plan.html, /src:url\(https:\/\/assets\.example\.test\/font\.woff2\)/);
  assert.match(plan.html, /content:"url\(https:\/\/assets\.example\.test\/example\.png\)"/);
  assert.match(plan.html, /image-set\( "https:\/\/mail\.invalid\/picture\/0" 1x, url\(https:\/\/mail\.invalid\/picture\/1\) 2x type\("image\/png"\) \)/);
  assert.match(plan.html, /background: url\(&quot;https:\/\/mail\.invalid\/picture\/6&quot;\); color: red/);
});

test('CSS escaped URL names, punctuation, hex escapes and quoted strings remain usable', () => {
  const source = String.raw`<style>.a{background:u\72l(https\3a //images.example.test/a\)b.png)}.b{background:image-set("https://images.example.test/c\20 d.png" 1x)}.c{background:url('https://images.example.test/e.png#icon\)')}</style>`;
  const plan = prepareStaticMailHtml(source);
  assert.deepEqual(plan.pictures.map(picture => picture.url), ['https://images.example.test/a)b.png',
    'https://images.example.test/c%20d.png', 'https://images.example.test/e.png']);
  assert.match(plan.html, /background:u\\72l\(https:\/\/mail\.invalid\/picture\/0\)/);
  assert.match(plan.html, /image-set\("https:\/\/mail\.invalid\/picture\/1" 1x\)/);
  assert.match(plan.html, /url\('https:\/\/mail\.invalid\/picture\/2#icon%29'\)/);
});

test('Relative/CID/data links and excluded network contexts are not planned or removed', () => {
  const source = '<img src="cid:photo"><img src="data:image/png;base64,AAAA"><img src="../photo.png">' +
    '<img src="https://mail.invalid/picture/old"><img src="https://mail.invalid./picture/old">' +
    '<img src="https://name:secret@example.test/photo"><img src="file:///photo">' +
    '<link href="https://assets.example.test/style.css" rel="stylesheet"><script src="https://assets.example.test/script.js"><img src="https://assets.example.test/example.png"></script>' +
    '<iframe src="https://assets.example.test/frame.html"></iframe><source src="https://assets.example.test/video.mp4">' +
    '<textarea><img src="https://assets.example.test/sample.png"></textarea>';
  const plan = prepareStaticMailHtml(source);
  assert.deepEqual(plan.pictures, []);
  assert.equal(plan.html, source);
  assert.equal(plan.overflow, false);
});

test('Per-snapshot local prefixes prevent collisions and reject non-local resource IDs', () => {
  const source = '<img src="https://images.example.test/a.png">';
  assert.equal(prepareStaticMailHtml(source, 'show', 'hide', 'https://mail.invalid/picture/7/').pictures[0].id, 'https://mail.invalid/picture/7/0');
  for (const invalid of ['https://evil.test/picture/', 'https://mail.invalid@evil.test/picture/', 'https://mail.invalid/picture/../', 'http://mail.invalid/picture/']) {
    assert.equal(prepareStaticMailHtml(source, 'show', 'hide', invalid).pictures[0].id, 'https://mail.invalid/picture/0');
  }
});

test('Plan limit reports overflow without truncating visible HTML or duplicating existing resources', () => {
  const source = Array.from({ length: 260 }, (_, index) => `<img alt="Picture ${index}" src="https://images.example.test/${index}.png">`).join('') +
    '<img src="https://images.example.test/0.png">';
  const plan = prepareStaticMailHtml(source);
  assert.equal(plan.pictures.length, 256);
  assert.equal(plan.overflow, true);
  assert.equal((plan.html.match(/<img /g) || []).length, 261);
  assert.match(plan.html, /alt="Picture 259" src="https:\/\/images\.example\.test\/259\.png"/);
  assert.ok(plan.html.endsWith('<img src="https://mail.invalid/picture/0">'));
});

test('Malformed HTML/CSS and very long whitespace remain bounded and source-preserving', () => {
  vm.runInNewContext(`
    for (const suffix of ['<a ', '<img title="', '<style>.x{background:url(', '<style>.x{background:image-set("']) {
      const source = suffix + ' '.repeat(200000);
      const plan = prepareStaticMailHtml(source);
      assert.equal(plan.html, source);
      assert.equal(plan.pictures.length, 0);
    }
  `, { prepareStaticMailHtml, assert }, { timeout: 2000 });
});
