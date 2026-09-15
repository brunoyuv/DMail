const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const vm = require('node:vm');
const compile = s => ts.transpileModule(s, { compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS } }).outputText;
const queueCode = compile(fs.readFileSync('harmony/entry/src/main/ets/pages/DeferredSave.ts', 'utf8'));
const microtasks = async () => { for(let n=0;n<20;n++) await Promise.resolve(); };
function pending() { let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b;});return{promise,resolve,reject}; }
function fixture() {
 let now=100000,nextId=0;const timers=new Map();const exports={};
 vm.runInNewContext(queueCode,{exports,Date:{now:()=>now},setTimeout:(fn,delay)=>{const id=++nextId;timers.set(id,{fn,at:now+delay});return id;},clearTimeout:id=>timers.delete(id)});
 return { Queue:exports.DeferredSave, timers, async advance(ms) {const end=now+ms;while(true){const due=[...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!due)break;now=due[1].at;timers.delete(due[0]);due[1].fn();await microtasks();}now=end;} };
}
function methods(file,names) {const source=fs.readFileSync(file,'utf8');return names.map(name=>source.match(new RegExp(`  private (?:async )?${name}\\([\\s\\S]*?\\n  }`))[0]).join('\n');}
test('Fast typing coalesces serialization and writes, with a two-second maximum quiet-save delay',async()=>{
 const f=fixture(), q=new f.Queue(), writes=[];
 for(let i=0;i<100;i++){q.schedule(async()=>{writes.push(i);});await f.advance(10);}
 assert.equal(writes.length,0);await f.advance(400);assert.deepEqual(writes,[99]);assert.equal(f.timers.size,0);
 for(let i=0;i<40;i++){q.schedule(async()=>{writes.push(i);});await f.advance(100);}
 await f.Queue.flushAll();assert.ok(writes.length<=4);assert.equal(writes.at(-1),39);
});
test('A slow save retains only the latest pending edit and does not grow timers or write chains',async()=>{
 const f=fixture(), q=new f.Queue(), gate=pending(), writes=[];
 q.schedule(async()=>{writes.push('first');await gate.promise;});await f.advance(400);
 for(let i=0;i<500;i++){q.schedule(async()=>{writes.push(i);});await f.advance(20);}
 assert.deepEqual(writes,['first']);assert.equal(f.timers.size,0);
 gate.resolve();await microtasks();await f.Queue.flushAll();assert.deepEqual(writes,['first',499]);
});
test('Explicit account/save boundaries submit the owned snapshot before later edits and wait for all writes',async()=>{
 const f=fixture(), q=new f.Queue(), gate=pending(), writes=[];
 q.schedule(async()=>{writes.push('A older');await gate.promise;});await f.advance(400);
 q.schedule(async()=>{writes.push('A final');});let done=false;const flush=q.flush().then(()=>{done=true;});
 assert.deepEqual(writes,['A older','A final']);await microtasks();assert.equal(done,false);
 q.schedule(async()=>{writes.push('B final');});q.flush();
 assert.deepEqual(writes,['A older','A final','B final']);gate.resolve();await flush;await f.Queue.flushAll();
});
test('Discard cancels unsaved edits and failed saves do not strand the queue or retry forever',async()=>{
 const f=fixture(), q=new f.Queue(), writes=[];
 q.schedule(async()=>{writes.push('discarded');});q.cancel();await f.advance(5000);assert.deepEqual(writes,[]);
 q.schedule(async()=>{writes.push('failed');throw new Error('synthetic');});await assert.rejects(q.flush());
 await f.Queue.flushAll();await f.advance(5000);assert.deepEqual(writes,['failed']);
 q.schedule(async()=>{writes.push('recovered');});await f.Queue.flushAll();assert.deepEqual(writes,['failed','recovered']);
});
test('Actual composer edit bursts preserve the latest large draft and ignore stale completion notices',async()=>{
 const f=fixture(), writes=[], gate=pending();
 const Host=new Function(compile(`class Host {${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets',['scheduleSave','save'])}}; return Host;`))();
 const draft={id:'draft-a',text:'',forwardHtml:'x'.repeat(1000000)};
 const host=Object.assign(new Host(),{account:{id:'a'},draft,active:true,saveRevision:0,saves:new f.Queue(),saveFailed:false,
  store:{saveOutgoing:async(account,value)=>{writes.push({account,text:value.text,bytes:JSON.stringify(value).length});if(writes.length===1)await gate.promise;}}});
 for(let i=0;i<100;i++){draft.text='edit '+i;host.scheduleSave();}assert.equal(writes.length,0);
 await f.advance(400);assert.equal(writes.length,1);assert.equal(writes[0].text,'edit 99');
 for(let i=100;i<500;i++){draft.text='edit '+i;host.scheduleSave();}gate.resolve();await f.Queue.flushAll();
 assert.equal(writes.length,2);assert.equal(writes[1].text,'edit 499');assert.equal(host.saveFailed,false);
});
test('Actual settings account changes preserve the captured sender and signature values',async()=>{
 const f=fixture(), writes=[];
 const Host=new Function(compile(`class Host {${methods('harmony/entry/src/main/ets/pages/Settings.ets',['scheduleComposition','saveComposition'])}}; return Host;`))();
 const host=Object.assign(new Host(),{active:true,compositionReady:true,selectedAccount:'a',accountGeneration:1,saveRevision:0,
  senderName:'Alice',signature:'A signature',saves:new f.Queue(),store:{saveComposition:async(id,value)=>{writes.push({id,...value});}}});
 host.scheduleComposition();host.saves.flush();host.selectedAccount='b';host.accountGeneration++;
 host.senderName='Bob';host.signature='B signature';host.scheduleComposition();await f.Queue.flushAll();
 assert.deepEqual(writes,[{id:'a',senderName:'Alice',signature:'A signature'},{id:'b',senderName:'Bob',signature:'B signature'}]);
});

test('Parent teardown waits for a send started by a held draft flush before closing storage',async()=>{
 const f=fixture(), saveGate=pending(), preflight=pending(), events=[];let sendWork=null;
 const background={isSending:()=>false,queue:()=>{events.push('send');sendWork=preflight.promise;return sendWork;},
  whenIdle:()=>{events.push('idle');return sendWork||Promise.resolve();}};
 const Compose=new Function('BackgroundSend',compile(`class Host {${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets',['editable','send'])}};return Host;`))(background);
 const q=new f.Queue();q.schedule(async()=>{await saveGate.promise;events.push('save');});
 const composer=Object.assign(new Compose(),{active:true,ready:true,busy:false,saves:q,draft:{state:'draft'},account:{id:'a'},
  host:'smtp.example.test',username:'a',password:'synthetic',settings:()=>({}),onQueued:()=>events.push('queued')});
 const sending=composer.send();await microtasks();assert.deepEqual(events,[]);
 const source=fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets','utf8');
 const lifecycle=source.match(/  aboutToDisappear\(\): void \{[\s\S]*?\n  }/)[0];
 const interaction=methods('harmony/entry/src/main/ets/pages/ConnectedMail.ets',['retireInboxInteraction']);
 const Parent=new Function('DeferredSave','MailOperations','BackgroundSend','MailNotificationService','AutomaticMailWork',compile(`class Host {${lifecycle}${interaction}};return Host;`))(
  f.Queue,{whenIdle:()=>Promise.resolve()},background,{setVisibleAccount:()=>{}},{cancelInactive:()=>{}});
 const parent=Object.assign(new Parent(),{notificationTimer:-1,inboxTimer:-1,inboxAnchorTimer:-1,inboxLoadRevision:0,
  mailboxRefreshRevision:0,generation:1,active:true,inboxSwipes:new Set(),inboxRequests:new Map(),unreadRefresh:Promise.resolve(),accountStore:{close:async()=>events.push('closed')}});
 parent.aboutToDisappear();saveGate.resolve();await microtasks();
 assert.deepEqual(events,['save','send','idle']);assert.equal(events.includes('closed'),false);
 preflight.resolve();await sending;await microtasks();assert.equal(events.at(-1),'closed');
});

test('Slow discard disables edits before deleting and never resurrects the discarded draft',async()=>{
 const f=fixture(), deletion=pending(), writes=[];let dialog,closed=false;
 const Host=new Function('BackgroundSend',compile(`class Host {${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets',['editable','addressChanged','scheduleSave','cancel'])}};return Host;`))({isSending:()=>false});
 const host=Object.assign(new Host(),{active:true,ready:true,busy:false,account:{id:'a'},draft:{state:'draft',to:'a@example.test'},
  saves:new f.Queue(),saveRevision:0,label:n=>n,onClose:()=>{closed=true;host.active=false;host.saves.flush();},
  getUIContext:()=>({showAlertDialog:value=>{dialog=value;}}),store:{clearOutgoing:async()=>{await deletion.promise;writes.push('delete');},saveOutgoing:async()=>writes.push('save')}});
 host.scheduleSave();host.cancel();const discard=dialog.secondaryButton.action();
 assert.equal(host.editable(),false);host.addressChanged('to','late@example.test');
 assert.equal(host.draft.to,'a@example.test');deletion.resolve();await discard;await f.Queue.flushAll();
 assert.equal(closed,true);assert.deepEqual(writes,['delete']);
});

test('A later composer initialization owns the draft while an earlier storage read is delayed',async()=>{
 const gate=pending();let reads=0;
 const Host=new Function('BackgroundSend',compile(`class Host {${methods('harmony/entry/src/main/ets/pages/ComposeMail.ets',['initialize'])}};return Host;`))({isSending:()=>false,wasAccepted:()=>false});
 const current={id:'current',state:'draft',text:'Current saved draft',cc:'',bcc:''};
 const host=Object.assign(new Host(),{active:true,initializeRevision:0,account:{id:'a'},loadRecipients:()=>{},savedFailureNotice:()=>'',
  store:{outgoing:()=>++reads===1?gate.promise:Promise.resolve(current),smtp:async()=>({endpoint:'smtp://example.test:587',username:'a',password:'synthetic'})}});
 const old=host.initialize();await host.initialize();assert.equal(host.draft,current);
 gate.resolve({...current,id:'old'});await old;assert.equal(host.draft,current);assert.equal(host.ready,true);
});

test('Parent teardown cancels the selected loader and waits for its retained body before closing storage',async()=>{
 const held=pending(),events=[];
 const source=fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets','utf8');
 const lifecycle=source.match(/  aboutToDisappear\(\): void \{[\s\S]*?\n  }/)[0];
 const interaction=methods('harmony/entry/src/main/ets/pages/ConnectedMail.ets',['retireInboxInteraction']);
 const Parent=new Function('DeferredSave','MailOperations','BackgroundSend','MailNotificationService','AutomaticMailWork',
  compile(`class Host {${lifecycle}${interaction}};return Host;`))(
  {flushAll:async()=>{}},{whenIdle:async()=>{}},{whenIdle:async()=>{}},{setVisibleAccount:()=>{}},{cancelInactive:()=>{}});
 const parent=Object.assign(new Parent(),{inboxTimer:-1,inboxAnchorTimer:-1,inboxLoadRevision:0,mailboxRefreshRevision:0,
  generation:1,active:true,inboxSwipes:new Set(),inboxRequests:new Map(),unreadRefresh:Promise.resolve(),
  messageLoader:{cancel:()=>events.push('cancel'),whenIdle:()=>{events.push('idle');return held.promise;}},
  accountStore:{close:async()=>events.push('closed')}});
 parent.aboutToDisappear();await microtasks();assert.deepEqual(events,['cancel','idle']);assert.equal(parent.messageLoader,undefined);
 held.resolve();await microtasks();assert.deepEqual(events,['cancel','idle','closed']);
});
