const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('../.tools/test/node_modules/typescript');
const { compareJmapInbox } = require('../.tools/test-output/mail/notifications/NotificationModel');
const { automaticMailFixture, flush } = require('./fixtures/automatic-mail-work.cjs');
const source = fs.readFileSync('harmony/entry/src/main/ets/mail/notifications/MailNotificationService.ets','utf8');
const code = ts.transpileModule(source.slice(source.indexOf('class CheckCredentials '),source.indexOf('interface ForegroundWatch '))+'\nexport { CheckEnvironment };',
  {compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
function fixture(jmap=false){
  const state={now:Date.now(),stopped:false,enabled:true,permission:true,available:true,pageCalls:0,checks:0,starts:[],writes:[],expireOnPage:false,credentialGate:null,credentialCalls:0,permissionGate:null};
  const automatic=automaticMailFixture(state);
  const page={emails:[{id:'new',preview:'new',receivedAt:2,keywords:[]},{id:'overlap',preview:'old',receivedAt:1,keywords:[]}],nextPosition:50,queryState:'page',notFound:[]};
  const cached={emails:[page.emails[1],{id:'tail',preview:'tail'}],nextPosition:100,queryState:'old'};
  const account={id:'a',serverId:'server',sessionUrl:jmap?'https://example.test/jmap':'imaps://example.test:993',username:'synthetic'};
  const settings={accountId:'a',cursor:'old',mailboxId:'inbox',revision:3};
  const record=kind=>state.starts.push({kind,at:state.now});
  const client={emailPage:async()=>{record('page');state.pageCalls++;if(state.expireOnPage)state.now+=60001;return page;}};
  const store={get mailSyncAvailable(){return state.available;},credentials:()=>({authorization:async()=>{state.credentialCalls++;if(state.credentialGate)await state.credentialGate;return 'synthetic';}}),
    notifications:{get:async()=>({enabled:state.enabled,revision:3})},badges:{beginCheck:async()=>null,record:async()=>{}},
    mail:{view:async()=>cached,saveView:async(...args)=>state.writes.push(args)}};
  for(const field of ['sync','pictures','documents'])Object.defineProperty(store,field,{get(){assert.fail('Background work cannot access '+field);}});
  class NativeImapClient{constructor(_,credentials){this.credentials=credentials;}async checkInbox(){await this.credentials.authorization();record('check');state.checks++;return {state:settings.resultState||'new',mailboxId:'inbox',newMessages:1};}async emailPage(...args){await this.credentials.authorization();return client.emailPage(...args);}}
  class NativeJmapAccountCore{async emailPage(...args){return client.emailPage(...args);}async mailboxes(){record('boxes');return[{id:'inbox',role:'inbox',countsKnown:false}];}}
  const module={exports:{}};
  new Function('module','exports','NativeImapClient','NativeJmapAccountCore','MailCache','NotificationPlatform','AutomaticMailWork','AutomaticMailWorkCancelled','compareJmapInbox','Date',code)(
    module,module.exports,NativeImapClient,NativeJmapAccountCore,{mutationRevision:()=>17},{isEnabled:async()=>{const gate=state.permissionGate;state.permissionGate=null;if(gate)await gate;return state.permission;}},automatic.AutomaticMailWork,automatic.AutomaticMailWorkCancelled,compareJmapInbox,automatic.Clock);
  const environment=new module.exports.CheckEnvironment({},store,[account],true,()=>state.stopped);
  return {state,page,cached,settings,environment,automatic,check:()=>automatic.settle(environment.check(settings))};
}
test('Scheduled IMAP checks preserve one header page and cached tail without creating bulk body/picture work',async()=>{
  const f=fixture();const result=await f.check();
  assert.equal(result.newMessages,1);assert.equal(f.state.pageCalls,1);assert.equal(f.state.writes.length,1);
  assert.deepEqual(f.state.writes[0][2].map(mail=>mail.id),['new','overlap','tail']);
  assert.equal(f.state.writes[0][5],17);assert.equal(f.state.starts[1].at-f.state.starts[0].at,3000);
  assert.equal(f.automatic.timers.size,0);assert.doesNotMatch(source,/MailBodySync|enqueuePage|enqueueCached|whenIdle/);
});
test('An unchanged IMAP cursor leaves 251 cached headers alone without resuming body backlog',async()=>{
  const f=fixture();f.cached.emails=Array.from({length:251},(_,i)=>({id:`cached-${i}`,preview:'saved'}));
  f.settings.resultState='old';await f.check();
  assert.equal(f.state.checks,1);assert.equal(f.state.pageCalls,0);assert.equal(f.state.writes.length,0);assert.equal(f.automatic.timers.size,0);
});
test('Scheduled JMAP checking reuses its existing header page and spaces optional count lookup',async()=>{
  const f=fixture(true);await f.check();
  assert.equal(f.state.pageCalls,1);assert.equal(f.state.writes.length,1);
  assert.deepEqual(f.state.starts.map(value=>value.kind),['page','boxes']);assert.equal(f.state.starts[1].at-f.state.starts[0].at,3000);
});
test('Missing optional cache schema and exhausted job time preserve arrivals without body work',async()=>{
  for(const mode of ['schema','deadline']){
    const f=fixture();if(mode==='schema')f.state.available=false;else f.state.expireOnPage=true;
    const result=await f.check();assert.equal(result.newMessages,1);assert.equal(f.state.writes.length,0,mode);
  }
});
test('Queued automatic checks revalidate permission and account settings before any socket',async()=>{
  for(const field of ['enabled','permission']){
    const f=fixture();await f.automatic.AutomaticMailWork.run(async()=>{});await flush();
    const pending=f.environment.check(f.settings);const rejected=assert.rejects(pending,f.automatic.AutomaticMailWorkCancelled);
    await flush();f.state[field]=false;await f.automatic.advance(3000);await rejected;
    assert.equal(f.state.starts.length,0,field);assert.equal(f.automatic.timers.size,0);
  }
});
test('Delayed credential completion cannot start a revoked automatic account check',async()=>{
  const f=fixture();let release;f.state.credentialGate=new Promise(resolve=>{release=resolve;});
  const pending=f.environment.check(f.settings);const rejected=assert.rejects(pending,f.automatic.AutomaticMailWorkCancelled);
  await flush();f.state.enabled=false;release();await rejected;await flush();assert.equal(f.state.starts.length,0);
});


test('Disabling during OS permission lookup prevents even credential refresh from starting', async () => {
  const f=fixture();let release;f.state.permissionGate=new Promise(resolve=>{release=resolve;});
  const pending=f.environment.check(f.settings);const rejected=assert.rejects(pending,f.automatic.AutomaticMailWorkCancelled);
  await flush();f.state.enabled=false;release();await rejected;await flush();
  assert.equal(f.state.credentialCalls,0);assert.equal(f.state.starts.length,0);assert.equal(f.automatic.timers.size,0);
});
