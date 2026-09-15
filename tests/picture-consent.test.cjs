// The reader keeps one HTML document while a bounded picture batch completes local resource responses.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { htmlContentInset, preparedMailDocument } = require('../.tools/test-output/mail/html/HtmlDocument');
const source = fs.readFileSync('harmony/entry/src/main/ets/pages/HtmlMail.ets', 'utf8');
function method(name) {
  let start = source.indexOf(`  private async ${name}(`);
  if (start < 0) start = source.indexOf(`  private ${name}(`);
  if (start < 0) start = source.indexOf(`  ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }\n', start) + 5).replace('private ', '');
}
const classSource = source.slice(source.indexOf('class HtmlReaderSnapshot'), source.indexOf('@Component'));
const names = ['aboutToAppear', 'aboutToDisappear', 'foregroundChanged', 'visibilityChanged', 'reload', 'captureSnapshot',
  'currentSnapshot', 'startPictures', 'receivePicture', 'finishPictures', 'cancelSnapshot', 'completeResponse', 'attachSnapshot', 'document', 'resourceResponse', 'blockNavigation', 'externalWebLink', 'launchLink'];
const compiled = ts.transpileModule(`${classSource}\nclass Harness {${names.map(method).join('\n')}}`, {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;
class Controller {
  active = 0; inactive = 0;
  onActive() { this.active++; }
  onInactive() { this.inactive++; }
}
class Response {
  setResponseData(value) { this.data = value; }
  setResponseHeader(value) { this.headers = value; }
  setResponseEncoding(value) { this.encoding = value; }
  setResponseMimeType(value) { this.type = value; }
  setResponseCode(value) { this.code = value; }
  setReasonMessage(value) { this.reason = value; }
  setResponseIsReady(value) { this.ready = value; this.transitions ||= []; this.transitions.push(value); }
}
const image = () => ({ data: new Uint8Array([1, 2, 3]).buffer, mimeType: 'image/png' });
function saved(messageKey = 'm', text = 'Persisted exact document') {
  return { version: 1, messageKey, bodySavedAt: 100, savedAt: 200,
    html: '<!doctype html><html><head><meta charset="UTF-8"></head><body><p>' + text + '</p>' +
      '<img src="https://mail.invalid/picture/saved/0" alt="Good">' +
      '<img src="https://mail.invalid/picture/saved/1" alt="Broken"></body></html>',
    pictures: [{ id: 'https://mail.invalid/picture/saved/0', url: 'https://images.example.test/good.png' },
      { id: 'https://mail.invalid/picture/saved/1', url: 'https://images.example.test/missing.png' }] };
}
function deferred() { let resolve; const promise = new Promise(r => resolve = r); return { promise, resolve }; }
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(batch) {
  const batches = [], violations = [], wrappers = [], timers = new Map(); let nextTimer = 0;
  const forbidden = name => (...args) => { violations.push(name); throw new Error(`Reader invoked forbidden ${name}`); };
  const Harness = new Function('webview', 'htmlContentInset', 'preparedMailDocument', 'WebResourceResponse',
    'loadPictureSnapshot', 'setTimeout', 'clearTimeout', `${compiled}; return Harness;`)(
    { WebviewController: Controller }, htmlContentInset,
    (...args) => { wrappers.push(args); return preparedMailDocument(...args); }, Response,
    async (...args) => {
      batches.push(args);
      if (batch) return batch(...args);
      const resources = args[3].map((url, index) => ({ url, picture: index === 0 ? image() : null,
        failure: index === 0 ? '' : 'network', status: 0 }));
      for (const resource of resources) args[6]?.(resource);
      return { resources, saved: true, cancelled: false };
    }, (callback, milliseconds) => { const id = ++nextTimer; timers.set(id, {callback,milliseconds}); return id; },
    id => timers.delete(id));
  const cancels = [];
  const cache = { cancelPending: (...args) => cancels.push(args),
    readSnapshot: forbidden('interceptor database'), loadWithStatus: forbidden('interceptor network') };
  const reader = Object.assign(new Harness(), {
    html: '<p>Raw saved fallback</p>', savedDocument: saved(), accountId: 'a', messageKey: 'm', pictureCache: cache,
    contentInset: 20, active: true, readerVisible: true, pictureForeground: true, documents: [], configured: false, reloadQueued: false,
    identityRevision: 0, configuredAccount: '', configuredMessage: '', openingLink: false,
    label: name => name, openLink: async () => {}
  });
  return { reader, batches, cancels, violations, wrappers, cache, timers };
}
function request(url, main = false, gesture = false) {
  return { getRequestUrl: () => url, isMainFrame: () => main, isRequestGesture: () => gesture };
}

test('HTML mounts immediately while a picture batch is held, and individual images complete without a document reload', async () => {
  const release = deferred(); let emit;
  const f = fixture(async (...args) => { emit = args[6]; await release.promise;
    return { resources: [], saved: true, cancelled: false }; });
  f.reader.reload(); await tick(); const snapshot = f.reader.documents[0];
  assert.equal(snapshot.html, f.reader.savedDocument.html); assert.equal(f.batches.length, 1);
  assert.equal(f.batches[0][4], false); assert.equal(f.batches[0][5].active(), true);
  assert.deepEqual(f.wrappers, []); assert.equal(f.timers.size, 1);
  const main = f.reader.resourceResponse(snapshot, request(snapshot.url, true));
  assert.equal(main.ready, true); assert.equal(main.code, 200); assert.equal(main.data, snapshot.html);
  const [good, slow] = f.reader.savedDocument.pictures;
  const goodResponse = f.reader.resourceResponse(snapshot, request(good.id));
  const slowResponse = f.reader.resourceResponse(snapshot, request(slow.id));
  assert.equal(goodResponse.ready, false); assert.equal(slowResponse.ready, false);
  const picture = image(); emit({ url:good.url, picture, failure:'',status:0 });
  assert.equal(goodResponse.ready,true); assert.equal(goodResponse.data,picture.data);
  assert.equal(slowResponse.ready,false); assert.deepEqual(goodResponse.transitions,[false,true]);
  assert.equal(f.reader.documents[0],snapshot); assert.equal(f.reader.documents.length,1);
  release.resolve(); await tick();
  assert.equal(slowResponse.ready,true); assert.equal(slowResponse.code,403);
  assert.equal(f.timers.size,0); assert.equal(snapshot.waitingCount,0); assert.deepEqual(f.violations,[]);
  assert.doesNotMatch(source,/prepareStaticMailHtml|runJavaScript|loadData\(|loadUrl\(|setInterval/);
});

test('Ready cached pictures and saved failures complete synchronously on every later resource callback', async () => {
  const f = fixture(); f.reader.reload(); await tick(); const snapshot=f.reader.documents[0];
  const [good,missing]=f.reader.savedDocument.pictures, bytes=snapshot.pictures.get(good.id).data;
  for(let i=0;i<1000;i++) {
    const picture=f.reader.resourceResponse(snapshot,request(good.id+'#part'));
    const broken=f.reader.resourceResponse(snapshot,request(missing.id));
    assert.equal(picture.data,bytes); assert.equal(picture.ready,true); assert.equal(picture.code,200);
    assert.equal(broken.code,403); assert.equal(broken.ready,true);
  }
  for(const target of ['https://outside.example.test/p.png','file:///secret','https://mail.invalid/favicon.ico'])
    assert.equal(f.reader.resourceResponse(snapshot,request(target)).code,403);
  assert.equal(f.batches.length,1); assert.deepEqual(f.violations,[]); assert.equal(f.timers.size,0);
  assert.match(source,/\.blockNetwork\(true\)/); assert.match(source,/\.javaScriptAccess\(false\)/);
});

test('Repeated metadata, theme and foreground updates neither rescan nor restart a completed picture attempt', async () => {
  const f=fixture(); f.reader.reload(); await tick(); const snapshot=f.reader.documents[0]; f.reader.attachSnapshot(snapshot);
  f.reader.savedDocument=saved('m','Later document'); f.reader.html='<p>New fallback</p>'; f.reader.contentInset=0;
  for(let i=0;i<100;i++)f.reader.reload();
  f.reader.pictureForeground=false;f.reader.foregroundChanged();f.reader.pictureForeground=true;f.reader.foregroundChanged();await tick();
  assert.equal(f.reader.documents[0],snapshot);assert.match(snapshot.html,/Persisted exact document/);
  assert.equal(f.batches.length,1);assert.equal(snapshot.controller.inactive,1);assert.equal(snapshot.controller.active,1);
  assert.equal(f.timers.size,0);assert.deepEqual(f.violations,[]);
});

test('Hidden or backgrounded readers cancel their one attempt, settle pending responses, and retain loaded bytes', async () => {
  for(const change of ['readerVisible','pictureForeground']) {
    const gate=deferred(); let emit;
    const f=fixture(async(...args)=>{emit=args[6];await gate.promise;return{resources:[],saved:false,cancelled:true};});
    f.reader.reload();await tick();const snapshot=f.reader.documents[0];f.reader.attachSnapshot(snapshot);
    const [good,slow]=f.reader.savedDocument.pictures;
    emit({url:good.url,picture:image(),failure:'',status:0});
    const pending=f.reader.resourceResponse(snapshot,request(slow.id)); assert.equal(pending.ready,false);
    f.reader[change]=false;f.reader.visibilityChanged();
    assert.deepEqual(f.cancels,[['a','m']]);assert.equal(pending.ready,true);assert.equal(pending.code,403);
    assert.equal(snapshot.controller.inactive,1);assert.equal(f.timers.size,0);assert.equal(f.batches[0][5].active(),false);
    f.reader[change]=true;f.reader.visibilityChanged();
    emit({url:slow.url,picture:image(),failure:'',status:0});gate.resolve();await tick();
    assert.equal(f.batches.length,1);assert.equal(snapshot.pictures.size,1);assert.deepEqual(pending.transitions,[false,true]);
    assert.equal(snapshot.controller.active,1);assert.equal(f.reader.documents[0],snapshot);
  }
});

test('The one deadline releases every pending native response even when a platform request remains held', async () => {
  const gate=deferred();const f=fixture(async()=>{await gate.promise;return{resources:[],saved:false,cancelled:true};});
  f.reader.reload();await tick();const snapshot=f.reader.documents[0];
  const response=f.reader.resourceResponse(snapshot,request(f.reader.savedDocument.pictures[0].id));
  const timer=[...f.timers.values()][0];assert.equal(timer.milliseconds,30000);timer.callback();
  assert.equal(response.ready,true);assert.equal(response.code,403);assert.equal(snapshot.waiting.size,0);assert.equal(f.timers.size,0);
  gate.resolve();await tick();assert.deepEqual(response.transitions,[false,true]);assert.equal(f.batches.length,1);
});

test('An old account, message, or removed reader cannot consume late picture results', async () => {
  const gate=deferred();let emit;
  const f=fixture(async(...args)=>{if(args[2]==='m'){emit=args[6];await gate.promise;}return{resources:[],saved:false,cancelled:true};});
  f.reader.reload();await tick();const old=f.reader.documents[0];
  const response=f.reader.resourceResponse(old,request(f.reader.savedDocument.pictures[0].id));
  f.reader.messageKey='next';f.reader.accountId='b';f.reader.savedDocument=saved('next','Next body');f.reader.reload();await tick();
  const current=f.reader.documents[0];assert.notEqual(current,old);assert.equal(response.ready,true);assert.equal(response.code,403);
  emit({url:'https://images.example.test/good.png',picture:image(),failure:'',status:0});gate.resolve();await tick();
  assert.equal(f.reader.documents[0],current);assert.equal(old.pictures.size,0);assert.equal(current.pictures.size,0);
  f.reader.aboutToDisappear();assert.deepEqual(f.reader.documents,[]);assert.equal(f.timers.size,0);
});

test('Picture storage or batch errors leave the full saved HTML usable and release every pending response', async () => {
  const gate=deferred();const f=fixture(async()=>{await gate.promise;throw new Error('Private database detail');});
  f.reader.reload();await tick();const snapshot=f.reader.documents[0];
  const response=f.reader.resourceResponse(snapshot,request(f.reader.savedDocument.pictures[0].id));
  gate.resolve();await tick();assert.equal(snapshot.html,f.reader.savedDocument.html);assert.equal(response.ready,true);
  assert.equal(response.code,403);assert.equal(f.timers.size,0);assert.doesNotMatch(JSON.stringify(snapshot),/Private database/);
});

test('Raw fallback and text-only saved documents render without any picture batch or body scanner', async () => {
  const f=fixture();f.reader.savedDocument=undefined;f.reader.html='<p>Raw 中文</p><img src="https://outside.example.test/broken.png">';
  f.reader.reload();await tick();assert.equal(f.batches.length,0);assert.equal(f.wrappers.length,1);
  assert.ok(f.reader.documents[0].html.includes(f.reader.html));assert.equal(f.timers.size,0);
  const g=fixture();g.reader.savedDocument={...saved(),pictures:[],html:'<html><body>Saved text</body></html>'};
  g.reader.reload();await tick();assert.equal(g.batches.length,0);assert.equal(g.wrappers.length,0);
  assert.equal(g.reader.documents[0].html,g.reader.savedDocument.html);assert.equal(g.timers.size,0);
});

test('Separately notified props freeze one correct identity before starting its picture batch', async () => {
  const f=fixture();f.reader.reload();await tick();
  f.reader.messageKey='next';f.reader.reload();f.reader.accountId='b';f.reader.reload();
  f.reader.savedDocument=saved('next','Correct new body');f.reader.reload();await tick();
  assert.equal(f.batches.length,2);assert.deepEqual(f.batches[1].slice(1,3),['b','next']);
  assert.match(f.reader.documents[0].html,/Correct new body/);assert.equal(f.timers.size,0);
});

test('A reader first mounted hidden defers its initial picture attempt until shown once', async () => {
  const f=fixture();f.reader.readerVisible=false;f.reader.reload();await tick();
  const snapshot=f.reader.documents[0];assert.equal(f.batches.length,0);assert.equal(snapshot.html,f.reader.savedDocument.html);
  f.reader.attachSnapshot(snapshot);assert.equal(snapshot.controller.inactive,1);
  f.reader.readerVisible=true;f.reader.visibilityChanged();await tick();assert.equal(f.batches.length,1);
  f.reader.visibilityChanged();await tick();assert.equal(f.batches.length,1);assert.equal(f.timers.size,0);
});

test('Duplicate local resource waits are bounded, complete once, and never trigger additional cache or network calls', async () => {
  const gate=deferred();let emit;const f=fixture(async(...args)=>{emit=args[6];await gate.promise;return{resources:[],saved:true,cancelled:false};});
  f.reader.reload();await tick();const snapshot=f.reader.documents[0],reference=f.reader.savedDocument.pictures[0];
  const responses=Array.from({length:1025},()=>f.reader.resourceResponse(snapshot,request(reference.id)));
  assert.equal(snapshot.waitingCount,1024);assert.equal(responses[1024].code,403);
  emit({url:reference.url,picture:image(),failure:'',status:0});
  emit({url:reference.url,picture:image(),failure:'',status:0});
  assert.equal(snapshot.waitingCount,0);for(const response of responses.slice(0,1024))assert.deepEqual(response.transitions,[false,true]);
  gate.resolve();await tick();assert.equal(f.batches.length,1);assert.deepEqual(f.violations,[]);assert.equal(f.timers.size,0);
});

test('Actual SQLite picture cache and batch render a fast image before a held image, then reopen failures without HTTP', async () => {
  const path=require('node:path'),{createRequire}=require('node:module');
  const filename=path.resolve('tests/picture-cache.test.cjs'),cacheSource=fs.readFileSync(filename,'utf8');
  const boundary=cacheSource.indexOf('\ntest(');assert.ok(boundary>0);
  const setup=new Function('require',cacheSource.slice(0,boundary)+'\nreturn {fixture,image,imageUrl};')(createRequire(filename));
  const gate=deferred(),fastReady=deferred();
  const urls=['cached','fast','slow','failed'].map(value=>setup.imageUrl+'?'+value);
  const c=await setup.fixture(async url=>{if(url===urls[2])await gate.promise;if(url===urls[3])throw new Error('Synthetic offline');return setup.image();});
  const make=()=>{
    const f=fixture((cache,account,key,requested,retry,scope,observer)=>c.snapshot(requested,retry,cache,account,key,scope,resource=>{
      observer(resource);if(resource.url===urls[1])fastReady.resolve();
    }));
    f.reader.pictureCache=c.cache;
    f.reader.savedDocument={...saved(),html:'<p>Body available before pictures</p>'+urls.map((_,i)=>`<img src="https://mail.invalid/picture/progressive/${i}">`).join(''),
      pictures:urls.map((url,i)=>({url,id:`https://mail.invalid/picture/progressive/${i}`}))};
    return f;
  };
  let f;
  try {
    await c.cache.allow('a','m');await c.cache.load('a','m',urls[0]);
    f=make();f.reader.reload();await tick();const snapshot=f.reader.documents[0];
    assert.ok(snapshot.html.includes('Body available before pictures'));
    const responses=f.reader.savedDocument.pictures.map(picture=>f.reader.resourceResponse(snapshot,request(picture.id)));
    await fastReady.promise;assert.equal(responses[0].ready,true);assert.equal(responses[1].ready,true);
    assert.equal(responses[2].ready,false);assert.equal(f.reader.documents[0],snapshot);assert.equal(f.batches.length,1);
    gate.resolve();await c.cache.whenIdle();await tick();
    assert.equal(responses[2].ready,true);assert.equal(responses[2].code,200);assert.equal(responses[3].code,403);
    assert.equal(c.calls.length,4);assert.equal(f.timers.size,0);assert.equal(f.reader.documents[0],snapshot);
    f.reader.aboutToDisappear();const reopened=make();reopened.reader.reload();await c.cache.whenIdle();await tick();
    const final=reopened.reader.documents[0];assert.equal(final.pictures.size,3);assert.equal(c.calls.length,4);
    assert.equal(reopened.reader.resourceResponse(final,request(reopened.reader.savedDocument.pictures[3].id)).code,403);
    reopened.reader.aboutToDisappear();assert.equal(reopened.timers.size,0);
  } finally {gate.resolve();f?.reader.aboutToDisappear();await c.cache.whenIdle();c.close();}
});

test('Native links require a user gesture and preserve local anchors within the saved document', async () => {
  const f = fixture(), opened = []; f.reader.openLink = async url => opened.push(url); f.reader.reload(); await tick();
  const snapshot = f.reader.documents[0];
  assert.equal(f.reader.blockNavigation(snapshot, request(snapshot.url + '#part', true)), false);
  assert.equal(f.reader.blockNavigation(snapshot, request('https://example.test/read', true)), true);
  assert.equal(opened.length, 0);
  assert.equal(f.reader.blockNavigation(snapshot, request('https://example.test/read', true, true)), true);
  await tick(); assert.deepEqual(opened, ['https://example.test/read']);
  for (const url of ['javascript:alert(1)', 'file:///secret', 'https://name:password@example.test/', 'https://mail.invalid/snapshot/nope', 'https://example.test/a\nb']) {
    assert.equal(f.reader.externalWebLink(url), false);
  }
});

test('Link failures remain generic and stale failures do not affect a different identity', async () => {
  const gate = deferred(), f = fixture(), toasts = [];
  f.reader.getUIContext = () => ({ getPromptAction: () => ({showToast: value => toasts.push(value)}) });
  f.reader.openLink = () => gate.promise; const launch = f.reader.launchLink('https://example.test/');
  ++f.reader.identityRevision; gate.resolve(); await launch; assert.deepEqual(toasts, []);
  f.reader.openLink = async () => { throw new Error('Private provider detail'); };
  await f.reader.launchLink('https://example.test/'); assert.deepEqual(toasts, [{message: 'link_open_error'}]);
});
