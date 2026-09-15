const { test }=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const ts=require('../.tools/test/node_modules/typescript');
for(const page of ['NotificationInboxPrompt','NotificationSettingsPanel']) {
 test(page+' checks OS permission only on foreground transitions, not on every inbox event',()=>{
  const source=fs.readFileSync('harmony/entry/src/main/ets/pages/'+page+'.ets','utf8');
  const method=source.match(/  private foregroundChanged\([\s\S]*?\n  }/)[0];let foreground=true,calls=0;
  const Host=new Function('MailInboxUpdates',ts.transpileModule(`class Host {${method}};return Host;`,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText)({isForeground:()=>foreground});
  const host=Object.assign(new Host(),{foreground:true,active:true,reload:()=>calls++,refreshSystem:()=>calls++});
  for(let i=0;i<1000;i++)host.foregroundChanged();assert.equal(calls,0);
  foreground=false;host.foregroundChanged();assert.equal(calls,0);
  foreground=true;host.foregroundChanged();assert.equal(calls,1);
  for(let i=0;i<1000;i++)host.foregroundChanged();assert.equal(calls,1);
  host.active=false;foreground=false;host.foregroundChanged();foreground=true;host.foregroundChanged();assert.equal(calls,1);
 });
}
