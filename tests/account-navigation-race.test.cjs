const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const ts=require('../.tools/test/node_modules/typescript');
const source=fs.readFileSync('harmony/entry/src/main/ets/pages/ConnectedMail.ets','utf8');
const method=source.match(/  private async openAccount\([\s\S]*?\n  }/)[0];
const code=ts.transpileModule(`class Host {${method}};return Host;`,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const Host=new Function('MailNotificationService','LOCAL_SENT_MAILBOX','AutomaticMailWork',code)(
 {setVisibleAccount:()=>{}},'local_sent',{cancelInactive:()=>{}});
function pending(){let resolve;const promise=new Promise(r=>resolve=r);return{resolve,promise};}
function fixture(){
 const loads=[],opened=[],paths=[],cancelled=[];
 const host=Object.assign(new Host(),{active:true,openInboxOnLaunch:true,generation:0,mailboxRefreshRevision:0,inboxLoadRevision:0,
  inboxTimer:-1,inboxAnchorTimer:-1,inboxSwipes:new Set(),conversationById:new Map(),conversationRevision:0,
  paths:{getAllPathName:()=>paths,clear:()=>{paths.length=0;}},resetInboxScroll:()=>{},loadMailAction:()=>{},clientFactory:{create:()=>({})},
  messageLoader:{cancel:()=>cancelled.push(true)},
  accountStore:{credentials:()=>({}),rememberVisitedAccount:async()=>{}},label:n=>n,
  loadBoxes(){const gate=pending();loads.push(gate);++this.generation;this.busy=true;return gate.promise;},
  async openBox(box){opened.push(box.id);++this.generation;},upgradeSentFolder:()=>{throw Error('Unexpected network');}});
 return{host,loads,opened,cancelled};
}
test('Old A → B → A account-loading continuations cannot reopen the current Inbox',async()=>{
 const {host,loads,opened,cancelled}=fixture();const a={id:'a',sessionUrl:'https://a.example.test/session'},b={id:'b',sessionUrl:'https://b.example.test/session'};
 const first=host.openAccount(a,true),middle=host.openAccount(b,true),latest=host.openAccount(a,true);
 host.boxes=[{id:'new-inbox',role:'inbox'}];host.busy=false;loads[2].resolve();await latest;
 assert.deepEqual(opened,['new-inbox']);loads[0].resolve();loads[1].resolve();await Promise.all([first,middle]);
 assert.deepEqual(opened,['new-inbox']);assert.equal(host.account.id,'a');
 assert.equal(cancelled.length,3,'Every explicit account navigation retires the old selected-message loader');
});
test('An account load completing after teardown does not navigate or publish a selection warning',async()=>{
 const {host,loads,opened}=fixture();host.accountStore.rememberVisitedAccount=async()=>{throw Error('Synthetic save failure');};
 const loading=host.openAccount({id:'a',sessionUrl:'https://a.example.test/session'},true);host.active=false;host.generation++;host.error='';
 host.boxes=[{id:'inbox',role:'inbox'}];host.busy=false;loads[0].resolve();await loading;
 assert.deepEqual(opened,[]);assert.equal(host.error,'');
});


// Run the production cached-box loading and one-shot role upgrade together.
// Only mailbox headers/roles are synthetic; there is no message-body fixture.
const roleMethods=['openAccount','loadBoxes','upgradeSentFolder'].map(name=>
 source.match(new RegExp('  private async '+name+'\\([\\s\\S]*?\\n  }'))[0]).join('\n');
const roleCode=ts.transpileModule(`class Host {${roleMethods}};return Host;`,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText;
const RoleHost=new Function('MailNotificationService','LOCAL_SENT_MAILBOX','AutomaticMailWork','MAILBOX_ROLE_REVISION','MailCache',roleCode)(
 {setVisibleAccount:()=>{}},'local_sent',{cancelInactive:()=>{}},4,{mutationRevision:()=>0});
function roleFixture(sessionUrl){
 const upgrade=pending(),done=pending(),calls=[];
 const boxes=[{id:'inbox',role:'inbox'},{id:'server_archive',role:null,mayAddItems:false,mayRemoveItems:false}];
 let cached={roleRevision:3,readOnly:false,boxes};
 const account={id:'a',serverId:'default',sessionUrl};
 const client={async mailboxes(id){calls.push(['mailboxes',id]);await upgrade.promise;
   return[{id:'inbox',role:'inbox',mayRemoveItems:true},{id:'server_archive',role:'archive',mayAddItems:true}];},
   async connect(){throw Error('Cached boxes should not delay Inbox with a session request');}};
 const host=Object.assign(new RoleHost(),{active:true,openInboxOnLaunch:true,generation:0,mailboxRefreshRevision:0,inboxLoadRevision:0,
   inboxTimer:-1,inboxAnchorTimer:-1,inboxSwipes:new Set(),conversationById:new Map(),conversationRevision:0,sentFolderUpdates:new Set(),
   paths:{getAllPathName:()=>[],clear:()=>{}},resetInboxScroll:()=>{},loadMailAction:()=>{},clientFactory:{create:()=>client},messageLoader:{cancel:()=>{}},
   accountStore:{credentials:()=>({}),rememberVisitedAccount:async()=>{},mail:{
     boxes:async()=>cached,saveBoxes:async(_id,values,readOnly)=>{calls.push(['saveBoxes']);cached={roleRevision:4,readOnly,boxes:values};}}},
   label:n=>n,refreshUnreadStatus:()=>{},showError:error=>{throw error;},saveCache:async operation=>operation,
   async applyBoxes(values){this.boxes=values;},async openBox(box){this.mailboxId=box.id;calls.push(['openInbox']);++this.generation;},
   async loadConversationIndex(){done.resolve();}});
 return{host,account,upgrade,done,calls,get cached(){return cached;}};
}

test('Old IMAP mailbox roles refresh once behind a cached Inbox without a local Sent folder',async()=>{
 const f=roleFixture('imaps://synthetic.example.test');
 await f.host.openAccount(f.account,true);
 assert.equal(f.host.mailboxId,'inbox');assert.equal(f.host.boxRolesCurrent,false);
 assert.equal(f.host.boxes.some(box=>box.id==='local_sent'),false);
 assert.deepEqual(f.calls,[['openInbox'],['mailboxes','default']]);
 // Reopening while metadata remains in flight must not request it again.
 await f.host.openAccount(f.account,true);
 assert.equal(f.calls.filter(call=>call[0]==='mailboxes').length,1);
 f.upgrade.resolve();await f.done.promise;
 assert.equal(f.host.boxRolesCurrent,true);assert.equal(f.cached.roleRevision,4);
 assert.equal(f.host.boxes.find(box=>box.id==='server_archive').role,'archive');
 assert.equal(f.calls.filter(call=>call[0]==='saveBoxes').length,1);
 await f.host.openAccount(f.account,true);
 assert.equal(f.calls.filter(call=>call[0]==='mailboxes').length,1);
});

test('Old JMAP mailbox metadata does not enter the IMAP folder-role upgrade',async()=>{
 const f=roleFixture('https://synthetic.example.test/session');
 await f.host.openAccount(f.account,true);
 assert.equal(f.host.mailboxId,'inbox');assert.equal(f.host.boxRolesCurrent,false);
 assert.deepEqual(f.calls,[['openInbox']]);assert.equal(f.cached.roleRevision,3);
});
