const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const ts = require('../.tools/test/node_modules/typescript');
const { prepareStaticMailHtml } = require('../.tools/test-output/mail/html/HtmlPicturePlan');
const html = require('../.tools/test-output/mail/html/HtmlDocument');
const { stableMessageKey } = require('../.tools/test-output/mail/Conversation');
const retention = 7 * 86400000;
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
const clone = value => JSON.parse(JSON.stringify(value));
const mail = (id, pictures = true) => ({ id, threadId: 'thread_'+id, messageIds: [id+'@example.test'], mailboxIds: ['inbox'],
  keywords: [], from: [], to: [], replyTo: [], subject: 'Synthetic '+id, preview: 'Saved preview', receivedAt: 123,
  hasAttachment: false, hasHtmlBody: true, bodyTruncated: false, bodyEncodingProblem: false,
  htmlBody: '<p>'+id+'</p>'+(pictures?'<img src="https://images.example.test/'+id+'.png">':''), textBody: 'Reply '+id });
const page = (ids, position = 0, nextPosition = null, queryState = 'epoch') => ({ accountId: 'server', position,
  nextPosition, queryState, emailState: null, total: null, emails: ids.map(id => mail(id)), notFound: [] });

// Exercise shipping queue/document stores against SQLite. Only native body
// transport, the raw-body cache boundary, and complete picture attempts are
// substituted; no real account, HTTP endpoint, or physical device is used.
async function fixture(read = async (_account, id) => mail(id), batch = async () => ({ saved: true, cancelled: false, resources: [] }), options = {}) {
  const state = { run: true, reads: [], pages: [], scans: 0, batches: [], saves: [], tracked: new Set(), cancels: [],
    now: Date.now(), failRead: false, failSave: false, failHeaders: false, queries: 0, yields: 0, rests: [], thermal: 0,
    nextPage: async () => { throw new Error('Unexpected page request'); } };
  const thermalListeners = new Set(), timers = new Map(); let timerSerial = 0;
  const runTimer = id => { const timer = timers.get(id); if (!timer) return;
    timers.delete(id); state.now = Math.max(state.now, timer.due); timer.done(); };
  const schedule = (done, delay) => { assert.ok(delay >= 0); state.yields++; if (delay > 0) state.rests.push(delay);
    const id = ++timerSerial; const timer = { done, due: state.now + delay, immediate: null }; timers.set(id, timer);
    if (!options.manualTimers && delay <= 10000) timer.immediate = setImmediate(() => runTimer(id)); return id; };
  const cancel = id => { const timer = timers.get(id); if (timer?.immediate) clearImmediate(timer.immediate); timers.delete(id); };
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec("CREATE TABLE accounts (id TEXT PRIMARY KEY, status TEXT); INSERT INTO accounts VALUES ('a','ready'),('b','ready')");
  sqlite.exec('CREATE TABLE mail_cache (account_id TEXT, kind TEXT, cache_key TEXT, payload TEXT, PRIMARY KEY (account_id,kind,cache_key))');
  const db = {
    executeSql: async (sql, args=[]) => sqlite.prepare(sql).run(...args),
    querySql: async (sql, args=[]) => {
      state.queries++; const statement=sqlite.prepare(sql); statement.setReturnArrays(true); const rows=statement.all(...args);let index=-1;
      return {goToFirstRow:()=>{index=0;return rows.length>0;},goToNextRow:()=>++index<rows.length,
        getString:column=>rows[index][column],getLong:column=>rows[index][column],getBlob:column=>new Uint8Array(rows[index][column]),close(){}};
    },beginTransaction:()=>sqlite.exec('BEGIN'),commit:()=>sqlite.exec('COMMIT'),rollBack:()=>sqlite.exec('ROLLBACK')
  };
  let tail=Promise.resolve();const queue=operation=>{const task=tail.catch(()=>{}).then(operation);tail=task.catch(()=>{});return task;};
  // Mirror the raw cache boundary's envelope metadata for shipping queue SQL.
  // Keep the existing Map API so fixture callers can seed/remove saved bodies.
  class BodyMap extends Map {
    set(key,value){const split=key.indexOf(':');sqlite.prepare("INSERT OR REPLACE INTO mail_cache VALUES (?,'email',?,?)")
      .run(key.slice(0,split),key.slice(split+1),JSON.stringify({version:1,savedAt:state.now,bodySavedAt:value.bodySavedAt,mail:value.mail}));return super.set(key,value);}
    delete(key){const split=key.indexOf(':');sqlite.prepare("DELETE FROM mail_cache WHERE account_id=? AND kind='email' AND cache_key=?")
      .run(key.slice(0,split),key.slice(split+1));return super.delete(key);}
    clear(){sqlite.exec("DELETE FROM mail_cache WHERE kind='email'");super.clear();}
  }
  const bodies=new BodyMap(),attempts=new Set(),headers=new Map(),modules=new Map();
  const fresh=time=>time!==null&&time<=state.now&&state.now-time<retention;
  class Clock extends Date { static now(){return state.now;} }
  function load(file) {
    file=path.resolve(file);if(modules.has(file))return modules.get(file);
    const module={exports:{}};modules.set(file,module.exports);
    const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
    new Function('require','module','exports','Date','setTimeout','clearTimeout',code)(name=>{
      if(name==='@kit.ArkTS')return {util:{generateRandomUUID:()=>require('node:crypto').randomUUID(),TextDecoder:class {
        static create(label,options){return new this(label,options);}
        constructor(label,options){this.decoder=new TextDecoder(label,options);}
        decodeToString(bytes){return this.decoder.decode(bytes);}
      }}};
      if(name.endsWith('/MailSyncPower'))return {MailSyncPower:{level:()=>state.thermal,subscribe:listener=>{thermalListeners.add(listener);return ()=>thermalListeners.delete(listener);}}};
      if(name.endsWith('/MailCache'))return {MailCache:{mutationRevision:()=>23}};
      if(name.endsWith('/MailCacheModel'))return {...require('../.tools/test-output/data/MailCacheModel'),cacheIsFresh:fresh,MAIL_RETENTION_MS:retention};
      if(name.endsWith('/Conversation'))return {stableMessageKey};
      if(name.endsWith('/HtmlDocument'))return html;
      if(name.endsWith('/HtmlPicturePlan'))return {prepareStaticMailHtml:(...args)=>{state.scans++;return prepareStaticMailHtml(...args);}};
      if(name.endsWith('/PictureSnapshot'))return {loadPictureSnapshot:async(_cache,a,k,urls,retry,scope)=>{
        const saved=await store.documents.read(a,k);assert.ok(saved.document,'document commits before image work');
        state.batches.push({a,k,urls,retry,scope});const result=await batch(state);if(!result.cancelled&&result.saved)attempts.add(a+':'+k);return result;
      }};
      if(!name.startsWith('.'))throw new Error('Unexpected '+name);
      const base=path.resolve(path.dirname(file),name);return load(fs.existsSync(base+'.ts')?base+'.ts':base+'.ets');
    },module,module.exports,Clock,schedule,cancel);
    return module.exports;
  }
  const {MailSyncStore}=load('harmony/entry/src/main/ets/data/MailSyncStore.ets');
  const {PreparedDocumentStore}=load('harmony/entry/src/main/ets/data/PreparedDocumentStore.ets');
  await MailSyncStore.initialize(db);await PreparedDocumentStore.initialize(db);
  const store={mailSyncAvailable:true,sync:new MailSyncStore(db,queue),documents:new PreparedDocumentStore(db,queue),
    trackMailSync:task=>{state.tracked.add(task);task.then(()=>state.tracked.delete(task),()=>state.tracked.delete(task));},
    mail:{email:async(a,id)=>{if(state.failRead)throw new Error('storage');const cached=bodies.get(a+':'+id);return cached&&fresh(cached.bodySavedAt)?clone(cached):null;},
      saveEmail:async(a,value,revision)=>{if(state.failSave)throw new Error('storage');
        if(sqlite.prepare("SELECT 1 FROM accounts WHERE id=? AND status='ready'").get(a)){
          bodies.set(a+':'+value.id,{mail:clone(value),bodySavedAt:state.now});state.saves.push(['body',a,value.id,revision]);}
      },saveSyncedEmails:async(a,emails,revision)=>{if(state.failHeaders)throw new Error('storage');
        for(const value of emails)headers.set(a+':'+value.id,clone(value));state.saves.push(['headers',a,emails.map(m=>m.id),revision]);}},
    pictures:{cancelPending:(a,k)=>state.cancels.push([a,k]),snapshotAttempted:async(a,k)=>attempts.has(a+':'+k)}};
  const {MailBodySync:Worker}=load('harmony/entry/src/main/ets/mail/MailBodySync.ets');
  const account={id:'a',serverId:'server'},client={readEmail:async(a,id)=>{state.reads.push([a,id]);return read(a,id,state);},
    emailPage:async(...args)=>{state.pages.push(args);return state.nextPage(...args);}};
  const workers=[];const createWorker=(scope)=>{const worker=new Worker(store,()=>state.run,scope);workers.push(worker);return worker;};
  const worker=createWorker();
  return {worker,Worker,createWorker,state,store,bodies,attempts,headers,account,client,sqlite,timers,
    advance:()=>{assert.ok(timers.size,'An actual backlog timer must exist');runTimer(timers.keys().next().value);},
    heat:level=>{state.thermal=level;for(const listener of thermalListeners)listener();},
    enqueue:ids=>worker.enqueue(client,account,ids.map(id=>mail(id)),'Show','Hide'),
    documents:()=>sqlite.prepare("SELECT message_key,payload FROM prepared_documents WHERE state='ready' ORDER BY message_key").all().map(row=>JSON.parse(row.payload)),
    jobs:()=>sqlite.prepare('SELECT * FROM mail_sync_jobs ORDER BY email_id').all(),
    reopenStores:()=>{store.sync=new MailSyncStore(db,queue);store.documents=new PreparedDocumentStore(db,queue);},
    close:async()=>{await Promise.all(workers.map(worker=>worker.close()));await tail;sqlite.close();}};
}

test('Sync saves serial per-ID bodies and immutable documents before picture attempts, then completed markers avoid repeat work',async()=>{
  let active=0,max=0;const f=await fixture(async(_a,id)=>{max=Math.max(max,++active);await tick();active--;return mail(id);});
  try{await f.enqueue(['one','two','one']);await f.worker.whenIdle();
    assert.equal(max,1);assert.deepEqual(f.state.reads.map(row=>row[1]),['one','two']);
    assert.equal(f.state.scans,2);assert.equal(f.state.batches.length,2);assert.ok(f.jobs().every(job=>job.stage==='done'));
    const saved=f.documents();await f.enqueue(['one','two']);await f.worker.whenIdle();
    assert.equal(f.state.scans,2);assert.equal(f.state.batches.length,2);assert.equal(f.state.reads.length,2);assert.deepEqual(f.documents(),saved);
  }finally{await f.close();}
});

test('Missing raw bodies recover on sync registration while immutable documents and settled picture attempts stay untouched',async()=>{
  const f=await fixture();
  try{
    await f.enqueue(['lost']);await f.worker.whenIdle();
    const saved=f.documents(),attempts=[...f.attempts],reads=f.state.reads.length,scans=f.state.scans,batches=f.state.batches.length;
    assert.equal(f.jobs()[0].stage,'done');f.bodies.delete('a:lost');f.state.now+=1000;
    await f.enqueue(['lost']);await f.worker.whenIdle();
    assert.equal(f.state.reads.length,reads+1);assert.ok(f.bodies.get('a:lost').mail.textBody);
    assert.deepEqual(f.documents(),saved);assert.deepEqual([...f.attempts],attempts);
    assert.equal(f.state.scans,scans);assert.equal(f.state.batches.length,batches);assert.equal(f.jobs()[0].stage,'done');
    await f.enqueue(['lost']);await f.worker.whenIdle();assert.equal(f.state.reads.length,reads+1);
    assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('All275 queued messages persist with bounded selections and every body finishes before slow pictures begin',async()=>{
  const f=await fixture(undefined,async state=>{assert.equal(state.reads.length,275);return {saved:true,cancelled:false,resources:[]};});
  try{f.state.run=false;await f.enqueue(Array.from({length:275},(_,i)=>String(i).padStart(3,'0')));
    assert.equal(f.jobs().length,275);assert.equal(f.state.reads.length,0);assert.equal(f.state.tracked.size,0);
    const queries=f.state.queries,yields=f.state.yields;await tick();await tick();assert.equal(f.state.queries,queries);assert.equal(f.state.yields,yields);
    f.state.run=true;f.worker.wake();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,275);assert.equal(f.documents().length,275);assert.equal(f.state.batches.length,275);
    assert.equal((await f.store.sync.next(['a'],'body',1)).length,0);assert.ok(f.jobs().every(job=>job.stage==='done'));
  }finally{await f.close();}
});

test('Automatic cursor traversal reaches every page without changing the visible mailbox or requiring load more',async()=>{
  const f=await fixture();
  try{f.state.nextPage=async(_a,_box,position,query)=>{assert.equal(query,'epoch');return position===3?page(['3','4','5'],3,6):page(['6'],6,null);};
    await f.worker.enqueuePage(f.client,f.account,'inbox',page(['0','1','2'],0,3),'Show','Hide');await f.worker.whenIdle();
    assert.deepEqual(f.state.pages.map(args=>args[2]),[3,6]);assert.equal(f.state.reads.length,7);assert.equal(f.documents().length,7);
    assert.deepEqual([...f.headers.keys()].sort(),['a:3','a:4','a:5','a:6']);assert.equal(await f.store.sync.nextCursor(['a']),null);
    await f.worker.enqueuePage(f.client,f.account,'inbox',page(['0','1','2'],0,3),'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.state.pages.length,2);assert.equal(f.state.reads.length,7);
  }finally{await f.close();}
});

test('Restart after an active body write preserves remaining durable jobs and the exact pagination checkpoint',async()=>{
  const f=await fixture(async(_a,id,state)=>{if(id==='1')state.run=false;return mail(id);});
  try{f.state.nextPage=async(_a,_box,position)=>position===3?page(['3','4','5'],3,6):page(['6'],6,null);
    const head=page(['0','1','2'],0,3);await f.worker.enqueuePage(f.client,f.account,'inbox',head,'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.bodies.size,2);assert.equal(f.documents().length,1);assert.equal((await f.store.sync.nextCursor(['a'])).position,3);
    await f.worker.close();f.reopenStores();const restarted=f.createWorker();f.state.run=true;
    await restarted.enqueueCached(f.client,f.account,'inbox',{savedAt:f.state.now,emails:head.emails,nextPosition:3,queryState:'epoch'},'Show','Hide');
    await restarted.whenIdle();assert.equal(f.state.reads.length,7);assert.equal(f.documents().length,7);
    assert.deepEqual(f.state.pages.map(args=>args[2]),[3,6]);assert.ok(f.jobs().every(job=>job.stage==='done'));
  }finally{await f.close();}
});

test('A cached mailbox seeds a missing cursor at its actual saved nextPosition, not its merged row count',async()=>{
  const f=await fixture();
  try{f.state.nextPage=async(_a,_box,position,query)=>{assert.equal(position,2);assert.equal(query,'epoch');return page(['new'],2,null);};
    await f.worker.enqueueCached(f.client,f.account,'inbox',{savedAt:f.state.now,emails:['0','1','tail1','tail2'].map(id=>mail(id)),nextPosition:2,queryState:'epoch'},'Show','Hide');
    await f.worker.whenIdle();assert.equal(f.state.reads.length,5);assert.equal(f.state.pages.length,1);
  }finally{await f.close();}
});

test('Every Sent/Inbox protocol ID gets reply text and attachments despite sharing one Message-ID document',async()=>{
  const shared=id=>({...mail(id),messageIds:['shared@example.test'],hasAttachment:true,attachments:[{id:'2',name:id+'.pdf'}]});
  const f=await fixture(async(_a,id)=>shared(id));
  try{await f.worker.enqueue(f.client,f.account,[shared('inbox_copy'),shared('sent_copy')],'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,1);assert.equal(f.state.batches.length,1);
    for(const id of ['inbox_copy','sent_copy']){assert.equal(f.bodies.get('a:'+id).mail.textBody,'Reply '+id);assert.equal(f.bodies.get('a:'+id).mail.attachments[0].name,id+'.pdf');}
  }finally{await f.close();}
});

test('Fresh partial/old decoder bodies are prepared once without repeated native safety-limit retries',async()=>{
  const f=await fixture();
  try{f.bodies.set('a:old',{mail:{...mail('old'),bodyTruncated:true,bodyEncodingProblem:true},bodySavedAt:f.state.now-1000});
    await f.enqueue(['old']);await f.worker.whenIdle();await f.enqueue(['old']);await f.worker.whenIdle();
    assert.equal(f.state.reads.length,0);assert.equal(f.state.scans,1);assert.equal(f.documents()[0].bodySavedAt,f.bodies.get('a:old').bodySavedAt);
  }finally{await f.close();}
});

test('Paused work survives close/reopen, saves the active body, and starts no successor or picture request',async()=>{
  const wait=deferred(),f=await fixture(async(_a,id)=>id==='one'?wait.promise:mail(id));
  try{await f.enqueue(['one','two']);await tick();f.state.run=false;f.worker.pause();wait.resolve(mail('one'));await f.worker.whenIdle();
    assert.equal(f.bodies.has('a:one'),true);assert.equal(f.state.scans,0);assert.equal(f.state.reads.length,1);assert.equal(f.jobs().length,2);
    await f.worker.close();f.reopenStores();const next=f.createWorker();f.state.run=true;
    await next.enqueue(f.client,f.account,[],'Show','Hide');await next.whenIdle();
    assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,2);
  }finally{wait.resolve(mail('one'));await f.close();}
});

test('Account cancellation prevents a late body write and removes its context from further durable selection',async()=>{
  const wait=deferred(),f=await fixture(()=>wait.promise);
  try{await f.enqueue(['one']);await tick();f.worker.cancelAccount('a');wait.resolve(mail('one'));await f.worker.whenIdle();
    assert.equal(f.bodies.size,0);assert.equal(f.documents().length,0);assert.equal(f.state.batches.length,0);
  }finally{wait.resolve(mail('one'));await f.close();}
});

test('Failed bodies remain durable through restart and retry automatically at their persisted deadline',async()=>{
  let fail=true;const f=await fixture(async(_a,id)=>{if(fail)throw new Error('network');return mail(id);});
  try{await f.enqueue(['one']);await f.worker.whenIdle();assert.equal(f.documents().length,0);assert.equal(f.jobs()[0].attempts,1);
    await f.worker.close();f.reopenStores();const next=f.createWorker();await next.enqueue(f.client,f.account,[],'Show','Hide');await next.whenIdle();
    assert.equal(f.state.reads.length,1);assert.equal(f.timers.size,1);fail=false;f.advance();await next.whenIdle();
    assert.equal(f.state.reads.length,2);assert.equal(f.documents().length,1);
  }finally{await f.close();}
});

test('Failed page storage does not advance the cursor or lose undiscovered jobs',async()=>{
  const f=await fixture();
  try{f.state.failHeaders=true;f.state.nextPage=async()=>page(['two'],1,null);
    await f.worker.enqueuePage(f.client,f.account,'inbox',page(['one'],0,1),'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.state.pages.length,1);assert.equal(f.jobs().some(job=>job.email_id==='two'),false);
    const cursor=f.sqlite.prepare('SELECT * FROM mail_sync_cursors').get();assert.equal(cursor.position,1);assert.equal(cursor.attempts,1);
    f.state.failHeaders=false;f.state.now+=61000;f.worker.wake();await f.worker.whenIdle();assert.equal(f.state.pages.length,2);assert.equal(f.bodies.size,2);
  }finally{await f.close();}
});

test('Stale pagination state restarts at the head on a later sync and retains already saved bodies',async()=>{
  const f=await fixture();let stale=true;
  try{f.state.nextPage=async(_a,_box,position,query)=>{
      if(stale){stale=false;const error=new Error('Safe stale state');error.code='stateMismatch';throw error;}
      if(position===0){assert.equal(query,undefined);return page(['new','one'],0,2,'new-epoch');}
      return page(['two'],2,null,'new-epoch');};
    await f.worker.enqueuePage(f.client,f.account,'inbox',page(['one'],0,1),'Show','Hide');await f.worker.whenIdle();
    const stored=f.sqlite.prepare('SELECT * FROM mail_sync_cursors').get();assert.equal(stored.position,0);assert.equal(stored.query_state,'');
    assert.deepEqual(f.state.pages.map(args=>args[2]),[1]);f.state.now+=61000;f.worker.wake();await f.worker.whenIdle();
    assert.deepEqual(f.state.pages.map(args=>args[2]),[1,0,2]);assert.deepEqual(f.state.reads.map(args=>args[1]).sort(),['new','one','two']);
  }finally{await f.close();}
});

test('Malformed/nonadvancing pages back off without checkpoint movement or an immediate retry loop',async()=>{
  const f=await fixture();
  try{f.state.nextPage=async()=>page(['bad'],1,1);await f.worker.enqueuePage(f.client,f.account,'inbox',page(['one'],0,1),'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.state.pages.length,1);assert.equal(f.jobs().some(job=>job.email_id==='bad'),false);
    const row=f.sqlite.prepare('SELECT * FROM mail_sync_cursors').get();assert.equal(row.position,1);assert.equal(row.attempts,1);
    const count=f.state.queries;await tick();await tick();assert.equal(f.state.queries,count);
  }finally{await f.close();}
});

test('Background deadline/permission gates new body and page sockets while retaining durable work',async()=>{
  for(const kind of ['body','page']){const f=await fixture();try{
    const scope={active:()=>true,deadline:f.state.now+60000,permitted:async()=>false};const worker=f.createWorker(scope);
    if(kind==='body')await worker.enqueue(f.client,f.account,[mail('one')],'Show','Hide');
    else await worker.enqueueCached(f.client,f.account,'inbox',{savedAt:f.state.now,emails:[],nextPosition:0},'Show','Hide');
    await worker.whenIdle();assert.equal(scope.revoked,true);assert.equal(f.state.reads.length,0);assert.equal(f.state.pages.length,0);
    assert.ok(kind==='body'?f.jobs().length===1:f.sqlite.prepare('SELECT count(*) AS n FROM mail_sync_cursors').get().n===1);
  }finally{await f.close();}}
});

test('A wake during canceled active pictures resumes the durable phase without rescanning saved HTML',async()=>{
  const wait=deferred();let batches=0;const f=await fixture(undefined,()=>++batches===1?wait.promise:Promise.resolve({saved:true,cancelled:false,resources:[]}));
  try{await f.enqueue(['one']);while(f.state.batches.length===0)await tick();
    f.worker.pause();f.worker.wake();wait.resolve({saved:false,cancelled:true,resources:[]});await f.worker.whenIdle();
    assert.equal(f.state.batches.length,2);assert.equal(f.state.scans,1);assert.equal(f.jobs()[0].stage,'done');
  }finally{wait.resolve({saved:false,cancelled:true,resources:[]});await f.close();}
});

test('Overlapping workers coalesce body, document and picture preparation with identical persisted picture IDs',async()=>{
  const wait=deferred(),f=await fixture(()=>wait.promise),other=f.createWorker();
  try{await f.enqueue(['one']);await other.enqueue(f.client,f.account,[mail('one')],'Show','Hide');await tick();wait.resolve(mail('one'));
    await Promise.all([f.worker.whenIdle(),other.whenIdle()]);assert.equal(f.state.reads.length,1);assert.equal(f.state.scans,1);assert.equal(f.state.batches.length,1);
    const first=f.documents();await other.enqueue(f.client,f.account,[mail('one')],'Other Show','Other Hide');await other.whenIdle();assert.deepEqual(f.documents(),first);
  }finally{wait.resolve(mail('one'));await f.close();}
});

test('Expired picture-stage work returns to body sync instead of silently completing missing content',async()=>{
  const f=await fixture(undefined,async()=>({saved:false,cancelled:true,resources:[]}));
  try{await f.enqueue(['one']);await f.worker.whenIdle();assert.equal(f.jobs()[0].stage,'pictures');f.state.now+=retention+1;
    f.worker.wake();await f.worker.whenIdle();assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,2);
  }finally{await f.close();}
});

test('Confirmed missing native mail is discarded while storage failures remain retryable',async()=>{
  const f=await fixture(async()=>null);
  try{await f.enqueue(['missing']);await f.worker.whenIdle();assert.equal(f.jobs().length,0);
    f.state.failRead=true;await f.enqueue(['saved']);await f.worker.whenIdle();assert.equal(f.state.reads.length,1);assert.equal(f.jobs()[0].attempts,1);
  }finally{await f.close();}
});

test('A future-dated prepared tombstone repairs once instead of spinning cached body and picture stages',async()=>{
  const f=await fixture();
  try{
    f.bodies.set('a:future',{mail:mail('future'),bodySavedAt:f.state.now});
    f.sqlite.prepare("INSERT INTO prepared_documents(account_id,message_key,body_saved_at,state,payload) VALUES (?,?,?,'expired','')")
      .run('a',stableMessageKey(mail('future')),f.state.now+3600000);
    await f.enqueue(['future']);await f.worker.whenIdle();
    assert.equal(f.state.reads.length,0);assert.equal(f.state.scans,1);assert.equal(f.state.batches.length,1);
    assert.equal(f.jobs()[0].stage,'done');assert.equal(f.documents()[0].bodySavedAt,f.bodies.get('a:future').bodySavedAt);
    const queries=f.state.queries,yields=f.state.yields;
    await tick();await tick();assert.equal(f.state.queries,queries);assert.equal(f.state.yields,yields);
    await f.enqueue(['future']);await f.worker.whenIdle();assert.equal(f.state.scans,1);assert.equal(f.state.batches.length,1);
  }finally{await f.close();}
});

test('An unusable prepared commit keeps durable backoff and a later sync can repair it without a stage cycle',async()=>{
  const f=await fixture();
  try{
    const save=f.store.documents.save.bind(f.store.documents);
    f.store.documents.save=async()=>({attempted:true,document:null,bodySavedAt:f.state.now+1,failure:'expired'});
    await f.enqueue(['blocked']);await f.worker.whenIdle();
    assert.equal(f.state.reads.length,1);assert.equal(f.state.scans,1);assert.equal(f.state.batches.length,0);
    assert.equal(f.jobs()[0].stage,'body');assert.equal(f.jobs()[0].attempts,1);assert.ok(f.jobs()[0].retry_at>f.state.now);
    const queries=f.state.queries,yields=f.state.yields;
    await tick();await tick();assert.equal(f.state.queries,queries);assert.equal(f.state.yields,yields);
    await f.enqueue(['blocked']);await f.worker.whenIdle();assert.equal(f.state.scans,1);
    f.store.documents.save=save;f.state.now+=61000;f.worker.wake();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,1);assert.equal(f.state.scans,2);assert.equal(f.jobs()[0].stage,'done');
  }finally{await f.close();}
});

test('A lost document in picture stage retains the body and defers one repair instead of immediately rescanning',async()=>{
  const f=await fixture(undefined,async()=>({saved:false,cancelled:true,resources:[]}));
  try{
    await f.enqueue(['lost']);await f.worker.whenIdle();assert.equal(f.jobs()[0].stage,'pictures');
    f.sqlite.exec('DELETE FROM prepared_documents');f.worker.wake();await f.worker.whenIdle();
    assert.equal(f.jobs()[0].stage,'body');assert.equal(f.jobs()[0].attempts,1);assert.ok(f.jobs()[0].retry_at>f.state.now);
    assert.equal(f.state.reads.length,1);assert.equal(f.state.scans,1);
    const queries=f.state.queries;await tick();await tick();assert.equal(f.state.queries,queries);
    f.state.now+=61000;f.worker.wake();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,1);assert.equal(f.state.scans,2);assert.equal(f.jobs()[0].stage,'pictures');
  }finally{await f.close();}
});


async function waitFor(predicate) { for (let i=0; i<100 && !predicate(); i++) await tick(); assert.ok(predicate()); }

test('Actual backlog rests after each item; repeated wake events cannot bypass the wait, and completion has no idle timer',async()=>{
  const f=await fixture(async(_a,id,state)=>{state.now+=600;return mail(id,false);},undefined,{manualTimers:true});
  try{await f.enqueue(['one','two']);await waitFor(()=>f.timers.size===1);
    assert.equal(f.state.reads.length,1);assert.deepEqual(f.state.rests,[600]);
    for(let i=0;i<100;i++)f.worker.wake();await tick();await tick();assert.equal(f.state.reads.length,1);assert.equal(f.timers.size,1);
    f.advance();await f.worker.whenIdle();assert.equal(f.state.reads.length,2);assert.ok(f.jobs().every(job=>job.stage==='done'));
    assert.equal(f.timers.size,0);const queries=f.state.queries;await tick();await tick();assert.equal(f.state.queries,queries);
  }finally{await f.close();}
});

test('Pausing a rest promptly drains the worker and retains its due time and all unfinished messages',async()=>{
  const f=await fixture(async(_a,id)=>mail(id,false),undefined,{manualTimers:true});
  try{await f.enqueue(['one','two']);await waitFor(()=>f.timers.size===1);f.worker.pause();await f.worker.whenIdle();
    assert.equal(f.timers.size,0);assert.equal(f.state.reads.length,1);assert.equal(f.jobs().filter(job=>job.stage==='body').length,1);
    f.worker.wake();await waitFor(()=>f.timers.size===1);assert.equal(f.state.reads.length,1);f.advance();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,2);assert.ok(f.jobs().every(job=>job.stage==='done'));
  }finally{await f.close();}
});

test('Thermal WARM pauses bulk work without polling, then cooling resumes the durable queue',async()=>{
  const f=await fixture(async(_a,id)=>mail(id,false),undefined,{manualTimers:true});
  try{f.heat(2);await f.enqueue(['one','two']);await f.worker.whenIdle();assert.equal(f.state.reads.length,0);assert.equal(f.timers.size,0);
    const queries=f.state.queries;await tick();await tick();assert.equal(f.state.queries,queries);
    f.heat(1);await waitFor(()=>f.timers.size===1);assert.equal(f.state.reads.length,1);assert.deepEqual(f.state.rests,[1000]);
    f.heat(3);await f.worker.whenIdle();assert.equal(f.timers.size,0);assert.equal(f.state.reads.length,1);
    f.heat(0);await waitFor(()=>f.timers.size===1);f.advance();await f.worker.whenIdle();assert.equal(f.state.reads.length,2);
  }finally{await f.close();}
});

test('Background deadline expires during a rest without starting another body request or dropping work',async()=>{
  const f=await fixture(async(_a,id)=>mail(id,false),undefined,{manualTimers:true});
  try{const worker=f.createWorker({active:()=>true,deadline:f.state.now+100});
    await worker.enqueue(f.client,f.account,[mail('one'),mail('two')],'Show','Hide');await waitFor(()=>f.timers.size===1);
    assert.deepEqual(f.state.rests,[100]);f.advance();await worker.whenIdle();assert.equal(f.state.reads.length,1);assert.equal(f.timers.size,0);
    assert.equal(f.jobs().filter(job=>job.stage==='body').length,1);
  }finally{await f.close();}
});

test('Closing during a rest cancels its timer and leaves pending work resumable by a new worker',async()=>{
  const f=await fixture(async(_a,id)=>mail(id,false),undefined,{manualTimers:true});
  try{await f.enqueue(['one','two']);await waitFor(()=>f.timers.size===1);await f.worker.close();assert.equal(f.timers.size,0);
    const next=f.createWorker();await next.enqueue(f.client,f.account,[],'Show','Hide');await next.whenIdle();
    assert.equal(f.state.reads.length,2);assert.ok(f.jobs().every(job=>job.stage==='done'));
  }finally{await f.close();}
});


function reusableClient(f, read) {
  const sessions=[], closed=[];
  f.client.readEmailForSync=async(a,id,token)=>{sessions.push({a,id,token});f.state.reads.push([a,id]);return read?read(a,id,token):mail(id,false);};
  f.client.closeSyncSession=async token=>{closed.push(token);};
  return {sessions,closed};
}

test('Sync reuses one account connection for consecutive missing bodies and closes it on completion',async()=>{
  const f=await fixture();const reuse=reusableClient(f);
  try{await f.enqueue(['one','two','three']);await f.worker.whenIdle();
    assert.equal(reuse.sessions.length,3);assert.equal(new Set(reuse.sessions.map(s=>s.token)).size,1);
    assert.deepEqual(reuse.closed,[reuse.sessions[0].token]);
    await f.enqueue(['one','two','three']);await f.worker.whenIdle();assert.equal(reuse.sessions.length,3);
  }finally{await f.close();}
});

test('Session pause and immediate resume rotate IDs; late close cannot target the resumed connection',async()=>{
  const f=await fixture(undefined,undefined,{manualTimers:true}),reuse=reusableClient(f);
  try{await f.enqueue(['one','two']);await waitFor(()=>f.timers.size===1);const first=reuse.sessions[0].token;
    f.worker.pause();await f.worker.whenIdle();assert.deepEqual(reuse.closed,[first]);
    f.worker.wake();await waitFor(()=>f.timers.size===1);f.advance();await f.worker.whenIdle();
    assert.notEqual(reuse.sessions[1].token,first);assert.deepEqual(reuse.closed,[first,reuse.sessions[1].token]);
  }finally{await f.close();}
});

test('Interrupted native sync reads remain pending without treating cancellation as a provider retry failure',async()=>{
  const wait=deferred(),f=await fixture();let first=true;
  const reuse=reusableClient(f,async(_a,id)=>{if(first){first=false;await wait.promise;throw new Error('cancelled native request');}return mail(id,false);});
  try{await f.enqueue(['one']);await waitFor(()=>reuse.sessions.length===1);f.worker.pause();wait.resolve();await f.worker.whenIdle();
    assert.equal(f.jobs()[0].stage,'body');assert.equal(f.jobs()[0].attempts,0);assert.equal(f.jobs()[0].retry_at,0);
    f.worker.wake();await f.worker.whenIdle();assert.equal(f.jobs()[0].stage,'done');assert.notEqual(reuse.sessions[0].token,reuse.sessions[1].token);
  }finally{wait.resolve();await f.close();}
});

test('Native failures close the session and back off once even when an ordinary wake arrives in flight',async()=>{
  const wait=deferred(),f=await fixture(),reuse=reusableClient(f,async()=>{await wait.promise;throw new Error('native network');});
  try{await f.enqueue(['one']);await waitFor(()=>reuse.sessions.length===1);f.worker.wake();wait.resolve();await f.worker.whenIdle();
    assert.equal(f.jobs()[0].attempts,1);assert.equal(reuse.sessions.length,1);assert.deepEqual(reuse.closed,[reuse.sessions[0].token]);
  }finally{wait.resolve();await f.close();}
});

test('Account cancellation closes its lease and client replacement cannot save an old late body',async()=>{
  const wait=deferred(),f=await fixture(),reuse=reusableClient(f,()=>wait.promise);
  try{await f.enqueue(['one']);await waitFor(()=>reuse.sessions.length===1);
    f.worker.cancelAccount('a');wait.resolve(mail('one',false));await f.worker.whenIdle();
    assert.deepEqual(reuse.closed,[reuse.sessions[0].token]);assert.equal(f.bodies.size,0);
    await f.worker.enqueue({readEmail:async(_a,id)=>mail(id,false)},f.account,[],'Show','Hide');await f.worker.whenIdle();
    assert.equal(f.bodies.size,1);assert.equal(f.jobs()[0].stage,'done');
  }finally{wait.resolve(mail('one',false));await f.close();}
});

test('Native body connections close before starting a picture batch',async()=>{
  let reuse;const f=await fixture(undefined,async()=>{assert.equal(reuse.closed.length,1);return {saved:true,cancelled:false,resources:[]};});
  reuse=reusableClient(f,async(_a,id)=>mail(id));
  try{await f.enqueue(['one']);await f.worker.whenIdle();assert.equal(f.state.batches.length,1);assert.equal(reuse.closed.length,1);
  }finally{await f.close();}
});


test('Transient body failures recover in a quiet Inbox without a manual refresh or arrival',async()=>{
  let fail=true;const f=await fixture(async(_a,id)=>{if(fail)throw new Error('network');return mail(id,false);});
  try{await f.enqueue(['one']);await f.worker.whenIdle();assert.equal(f.state.reads.length,1);assert.equal(f.timers.size,1);
    assert.equal(f.jobs()[0].attempts,1);const queries=f.state.queries;await tick();await tick();assert.equal(f.state.queries,queries);
    fail=false;f.advance();await f.worker.whenIdle();assert.equal(f.state.reads.length,2);assert.equal(f.jobs()[0].stage,'done');assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('Retry deadlines do not bypass thermal pause, and cooling schedules remaining unfinished work',async()=>{
  let fail=true;const f=await fixture(async(_a,id)=>{if(fail)throw new Error('network');return mail(id,false);});
  try{await f.enqueue(['one']);await f.worker.whenIdle();assert.equal(f.timers.size,1);f.heat(2);await f.worker.whenIdle();assert.equal(f.timers.size,0);
    f.state.now+=61000;fail=false;f.heat(0);await f.worker.whenIdle();assert.equal(f.state.reads.length,2);assert.equal(f.jobs()[0].stage,'done');
  }finally{await f.close();}
});

test('Repeated provider failures keep one exponentially backed-off wake and no repeated HTML or completed-picture work',async()=>{
  const f=await fixture(async()=>{throw new Error('network');});
  try{await f.enqueue(['one']);await f.worker.whenIdle();const first=f.jobs()[0].retry_at-f.state.now;
    assert.equal(first,60000);assert.equal(f.timers.size,1);f.advance();await f.worker.whenIdle();
    assert.equal(f.jobs()[0].retry_at-f.state.now,120000);assert.equal(f.timers.size,1);assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,0);
    await f.worker.close();assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('Retry wakes beyond a scheduled job deadline remain persisted without keeping that job alive',async()=>{
  const f=await fixture(async()=>{throw new Error('network');});
  try{const worker=f.createWorker({active:()=>true,deadline:f.state.now+30000});
    await worker.enqueue(f.client,f.account,[mail('one')],'Show','Hide');await worker.whenIdle();assert.equal(f.jobs()[0].attempts,1);assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('A failed empty decode is not cached or scanned and recovers with bounded backoff',async()=>{
  let failed=true;const f=await fixture(async(_a,id)=>failed?({...mail(id,false),textBody:null,htmlBody:null,bodyEncodingProblem:true}):mail(id,false));
  try{await f.enqueue(['failed-empty']);await f.worker.whenIdle();
    assert.equal(f.state.reads.length,1);assert.equal(f.bodies.size,0);assert.equal(f.state.scans,0);assert.equal(f.documents().length,0);
    assert.equal(f.jobs()[0].stage,'body');assert.equal(f.jobs()[0].attempts,1);assert.equal(f.timers.size,1);
    failed=false;f.advance();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,1);assert.equal(f.jobs()[0].stage,'done');assert.equal(f.timers.size,0);
    await f.enqueue(['failed-empty']);await f.worker.whenIdle();assert.equal(f.state.reads.length,2);assert.equal(f.state.scans,1);
  }finally{await f.close();}
});

test('Old failed-empty cached bytes cannot satisfy a recovered body job, while usable partial and valid empty bodies stay complete',async()=>{
  const f=await fixture(async(_a,id)=>id==='partial'?({...mail(id,false),bodyEncodingProblem:true,bodyTruncated:true}):
    id==='empty'?({...mail(id,false),textBody:'',htmlBody:null}):
    id==='attachment'?({...mail(id,false),textBody:'',htmlBody:null,hasAttachment:true,attachments:[]}):mail(id,false));
  try{f.bodies.set('a:recovered',{bodySavedAt:f.state.now,mail:{...mail('recovered',false),textBody:null,htmlBody:null,bodyEncodingProblem:true}});
    await f.enqueue(['recovered','partial','empty','attachment']);await f.worker.whenIdle();assert.equal(f.state.reads.length,4);
    assert.ok(f.bodies.get('a:recovered').mail.textBody);assert.ok(f.jobs().every(job=>job.stage==='done'));
    await f.enqueue(['recovered','partial','empty','attachment']);await f.worker.whenIdle();assert.equal(f.state.reads.length,4);assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('A retry becoming due between the last queue selection and scheduling still receives one wake',async()=>{
  let failed=true;const f=await fixture(async(_a,id)=>{if(failed)throw new Error('temporary failure');return mail(id,false);},undefined,{manualTimers:true});
  try{const retry=f.store.sync.nextRetryAt.bind(f.store.sync);let crossed=false;
    f.store.sync.nextRetryAt=async accounts=>{if(!crossed){crossed=true;f.state.now+=61000;}return retry(accounts);};
    await f.enqueue(['boundary']);await f.worker.whenIdle();assert.equal(f.state.reads.length,1);assert.equal(f.timers.size,1);
    assert.equal(f.jobs()[0].retry_at<f.state.now,true);failed=false;f.advance();await f.worker.whenIdle();
    assert.equal(f.state.reads.length,2);assert.equal(f.jobs()[0].stage,'done');assert.equal(f.timers.size,0);
  }finally{await f.close();}
});

test('A corrupt overdue queue record cannot create a repeated deadline query loop',async()=>{
  const f=await fixture(undefined,undefined,{manualTimers:true});
  try{f.state.run=false;await f.enqueue(['corrupt']);
    f.sqlite.prepare("UPDATE mail_sync_jobs SET payload='invalid JSON',attempts=1,retry_at=?").run(f.state.now-1000);
    f.state.run=true;f.worker.wake();await f.worker.whenIdle().catch(()=>{});await tick();
    assert.equal(f.timers.size,0);const queries=f.state.queries;await tick();await tick();assert.equal(f.state.queries,queries);
    assert.equal(f.state.reads.length,0);
  }finally{await f.close();}
});
