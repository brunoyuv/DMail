// PDF attachment and cache checks against the shipping Swift and ArkUI code.
import { describe, it, expect } from '@ohos/hypium';
import { Driver, ON } from '@ohos.UiTest';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
interface Session { attachmentDownloads?: number; }
interface Stats { sessions: Session[]; active: number; }
interface PDF { bytes: number; sha256: string; }
async function get(path: string): Promise<string> {
  const request=http.createHttp();
  try {return (await request.request(`http://localhost:9760${path}`)).result as string;} finally {request.destroy();}
}
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('corpus:fixture-password'))}`;
  }
}
export default function tests(): void {
  describe('AttachmentsAndCache',()=>{
    it('pdf_opens_from_attachment_row_and_reopening_mail_uses_cache',0,async()=>{
      const driver=Driver.create();await driver.wakeUpDisplay();
      const screen=display.getDefaultDisplaySync();
      await driver.swipe(Math.floor(screen.width/2),Math.floor(screen.height*.8),Math.floor(screen.width/2),Math.floor(screen.height*.2),600);
      await driver.delayMs(5000);
      const delegator=abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor={abilityName:'IMAPTestAbility'};
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({bundleName:'org.thunderbird.harmony.imaptest',moduleName:'entry_test',abilityName:'IMAPTestAbility'});
      const ability=await delegator.waitAbilityMonitor(monitor,5000) as IMAPTestAbility;
      const store=new AccountStore('mail_features_test.db');await store.open(ability.context);
      try {
        for(const account of await store.list()) await store.remove(account.id);
        const credentials=new Credentials(),client=new NativeImapClient('imaps://localhost:9761',credentials);
        const session=await client.connect();
        const account=await store.add('imaps://localhost:9761',session.accounts[0],(await credentials.authorization()).slice(6),'reader@example.test');
        const page=await client.emailPage(account.serverId,(await client.mailboxes(account.serverId))[0].id);
        const summary=page.emails.find(mail=>mail.subject==='large-pdf.eml')!;
        const mail=await client.readEmail(account.serverId,summary.id);
        expect(mail?.attachments?.length).assertEqual(1);
        expect(mail?.attachments?.[0].name).assertEqual('report.pdf');
        expect(mail?.attachments?.[0].contentType).assertEqual('application/pdf');
        const before=JSON.parse(await get('/stats')) as Stats;
        expect(before.sessions.reduce((sum,item)=>sum+(item.attachmentDownloads||0),0)).assertEqual(0);
        await AppLanguage.set(ability.context,'en');await ability.showMailFeaturesFixture();
        await (await driver.waitForComponent(ON.id(`remote-mail-${summary.id}`).enabled(true),10000)).click();
        await driver.waitForComponent(ON.id('reply-mail').enabled(true),10000);await driver.delayMs(700);
        expect(await driver.waitForComponent(ON.id('attachment-2').enabled(true),5000)!==null).assertTrue();
        await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/attachment-reader.png');
        const first=JSON.parse(await get('/stats')) as Stats;
        expect(first.active).assertEqual(0);
        await driver.pressBack();
        await (await driver.waitForComponent(ON.id(`remote-mail-${summary.id}`).enabled(true),5000)).click();
        await driver.waitForComponent(ON.id('reply-mail').enabled(true),5000);await driver.delayMs(500);
        const repeated=JSON.parse(await get('/stats')) as Stats;
        expect(repeated.sessions.length).assertEqual(first.sessions.length);
        console.info('ATTACHMENT_CACHE: repeated open made zero IMAP connections');
        await (await driver.findComponent(ON.id('attachment-2').enabled(true))).click();await driver.delayMs(2500);
        const folder=`${ability.context.cacheDir}/mail-attachments/${account.id}`;
        expect(fs.accessSync(folder)).assertTrue();
        const names=fs.listFileSync(folder).filter(name=>name.endsWith('-report.pdf'));
        expect(names.length).assertEqual(1);
        const path=`${folder}/${names[0]}`, expected=JSON.parse(await get('/corpus/pdf')) as PDF;
        expect(fs.statSync(path).size).assertEqual(expected.bytes);
        const file=fs.openSync(path,fs.OpenMode.READ_ONLY);const buffer=new ArrayBuffer(expected.bytes);
        try {expect(fs.readSync(file.fd,buffer)).assertEqual(expected.bytes);} finally {fs.closeSync(file);}
        const md=cryptoFramework.createMd('SHA256');await md.update({data:new Uint8Array(buffer)});
        const hash=Array.from((await md.digest()).data).map((value:number)=>value.toString(16).padStart(2,'0')).join('');
        expect(hash).assertEqual(expected.sha256);
        const downloaded=JSON.parse(await get('/stats')) as Stats;
        expect(downloaded.sessions.reduce((sum,item)=>sum+(item.attachmentDownloads||0),0)).assertEqual(1);
        console.info(`ATTACHMENT_PDF: ${expected.bytes} bytes, verified SHA256 ${hash}`);
        await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/attachment-open.png');
      } finally {
        await ability.context.terminateSelf();for(const account of await store.list()) await store.remove(account.id);
        await store.close();await delegator.removeAbilityMonitor(monitor);
      }
    });
  });
}
