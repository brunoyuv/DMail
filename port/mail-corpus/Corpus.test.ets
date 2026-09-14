// Public MimeKit fixtures are read by the same native adapter and UI as live mail.
import { describe, it, expect } from '@ohos/hypium';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { Driver, ON } from '@ohos.UiTest';
import { AppLanguage } from '../../../main/ets/settings/AppLanguage';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';
import IMAPTestAbility from '../abilities/IMAPTestAbility';
interface Case { uid: number; name: string; expected: string; }
interface Result { name: string; text: string; html: boolean; inlineImages: number; imageUri: string; encodingProblem: boolean; error: string; }
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> {
    return `Basic ${new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto('corpus:fixture-password'))}`;
  }
}
export default function tests(): void {
  describe('PublicMailCorpus', () => {
    for(let batch=0;batch<3;batch++) {
    it(`native_reader_and_ui_batch_${batch}`, 0, async () => {
      const select=http.createHttp();
      try {expect((await select.request(`http://localhost:9760/corpus/batch/${batch}`,{method:http.RequestMethod.POST})).responseCode).assertEqual(200);} finally {select.destroy();}
      const driver=Driver.create(); await driver.wakeUpDisplay();
      const screen=display.getDefaultDisplaySync();
      console.info(`CORPUS_SCREEN ${screen.width}x${screen.height} density=${screen.densityPixels}`);
      await driver.swipe(Math.floor(screen.width/2),Math.floor(screen.height*0.8),Math.floor(screen.width/2),Math.floor(screen.height*0.2),600);
      // Cold boot unlock can precede the emulator credential service becoming
      // ready. Let the system finish before creating DEVICE_UNLOCKED assets.
      if(batch===0) { await driver.delayMs(5000); }
      const delegator=abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor={abilityName:'IMAPTestAbility'};
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({bundleName:'org.thunderbird.harmony.imaptest',moduleName:'entry_test',abilityName:'IMAPTestAbility'});
      const ability=await delegator.waitAbilityMonitor(monitor,5000) as IMAPTestAbility;
      const store=new AccountStore('mail_features_test.db');await store.open(ability.context);
      const results: Result[]=[];
      try {
        for(const account of await store.list()) await store.remove(account.id);
        const credentials=new Credentials();const client=new NativeImapClient('imaps://localhost:9761',credentials);
        const session=await client.connect();
        const account=await store.add('imaps://localhost:9761',session.accounts[0],(await credentials.authorization()).slice(6),'reader@example.test');
        const page=await client.emailPage(account.serverId,(await client.mailboxes(account.serverId))[0].id);
        const request=http.createHttp();let cases: Case[]=[];
        try {cases=JSON.parse((await request.request('http://localhost:9760/corpus')).result as string) as Case[];} finally {request.destroy();}
        expect(page.emails.length).assertEqual(cases.length);
        await AppLanguage.set(ability.context,'en');await ability.showMailFeaturesFixture();
        await driver.waitForComponent(ON.id('compose-mail').enabled(true),10000);
        await driver.delayMs(500);
        if(batch===0) { await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/corpus-inbox.png'); }
        await (await driver.findComponent(ON.id('compose-mail'))).click();
        await driver.waitForComponent(ON.id('compose-to'),5000);await driver.delayMs(300);
        if(batch===0) { await delegator.executeShellCommand('uitest screenCap -p /data/local/tmp/corpus-compose.png'); }
        await (await driver.findComponent(ON.id('cancel-compose'))).click();await driver.delayMs(300);
        for(const summary of page.emails) {
          const fixture=cases.find(value=>value.name===summary.subject)!;
          const result: Result={name:fixture.name,text:'',html:false,inlineImages:0,imageUri:'',encodingProblem:false,error:''};
          console.info(`CORPUS_CASE ${fixture.name}`);
          let opened = false;
          try {
            const mail=await client.readEmail(account.serverId,summary.id);
            result.text=mail?.textBody?.slice(0,300)||'';result.html=!!mail?.htmlBody;
            result.inlineImages=(mail?.htmlBody?.match(/data:image\//g)||[]).length;
            result.imageUri=mail?.htmlBody?.match(/src=["'](data:image[^"']+)/)?.[1]||'';
            result.encodingProblem=mail?.bodyEncodingProblem||false;
            if(fixture.name==='multipart-related-mhtml.txt' && result.inlineImages===0) result.error='Content-Location image missing';
            if(fixture.name==='large-pdf.eml') expect(mail?.hasAttachment).assertTrue();
            if(fixture.expected && !(mail?.textBody||mail?.htmlBody||'').includes(fixture.expected)) result.error='Expected body text missing';
            let list=await driver.waitForComponent(ON.id('mail-list'),2000);
            if(list===null) {
              await delegator.startAbility({bundleName:'org.thunderbird.harmony.imaptest',moduleName:'entry_test',abilityName:'IMAPTestAbility'});
              await ability.showMailFeaturesFixture();list=await driver.waitForComponent(ON.id('mail-list'),5000);
            }
            if(list===null) throw new Error('Inbox not available');
            let row=await driver.findComponent(ON.id(`remote-mail-${summary.id}`).enabled(true));
            for(let attempt=0;row===null&&attempt<24;attempt++) {
              const area=await (await driver.findComponent(ON.id('mail-list'))).getBounds();
              const top=Math.max(area.top+30,80), bottom=Math.min(area.bottom-60,screen.height-100);
              console.info(`CORPUS_LIST ${JSON.stringify(area)} swipe=${top}:${bottom}`);
              if(bottom<=top+30) throw new Error('Inbox too small to scroll');
              const x=Math.floor((area.left+area.right)/2);
              await driver.swipe(x,Math.floor(bottom),x,Math.floor(top),600);await driver.delayMs(200);
              row=await driver.findComponent(ON.id(`remote-mail-${summary.id}`).enabled(true));
            }
            if(row===null) throw new Error('Message row not reachable');
            await row.click();opened=true;await driver.waitForComponent(ON.id('reply-mail').enabled(true),10000);
            const title=await driver.waitForComponent(ON.id('reader-subject'),5000);
            expect(await title.getText()).assertEqual(fixture.name);
            if(result.html) {
              const web=await driver.waitForComponent(ON.id('html-mail'),5000);
              const bounds=await web.getBounds();
              if(bounds.left<0||bounds.right>screen.width+2) throw new Error('HTML viewport outside screen');
            }
            await driver.waitForIdle(300,3000);
            await driver.delayMs(result.html ? 1200 : 350);
            let edgeVerified=false;
            if(fixture.name==='wide-newsletter.eml') {
              const marker=await driver.findComponent(ON.text('RIGHT EDGE'));
              if(marker!==null) {
                const edge=await marker.getBounds();const pane=await (await driver.findComponent(ON.id('reader-scroll'))).getBounds();
                edgeVerified=edge.right<=pane.right+2&&edge.left>=pane.left-2;
                if(!edgeVerified) result.error='Newsletter right edge clipped';
              }
            }
            await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/corpus-${fixture.uid}.png`);
            if(result.html) {
              const bounds=await (await driver.findComponent(ON.id('reader-scroll'))).getBounds();
              const x=Math.floor((bounds.left+bounds.right)/2);
              await driver.swipe(x,Math.floor(bounds.top+(bounds.bottom-bounds.top)*0.85),x,Math.floor(bounds.top+(bounds.bottom-bounds.top)*0.15),700);
              await driver.delayMs(350);
              if(fixture.name==='wide-newsletter.eml'&&!edgeVerified) {
                let marker=await driver.findComponent(ON.text('RIGHT EDGE'));
                for(let attempt=0;marker===null&&attempt<2;attempt++) {
                  await driver.swipe(x,Math.floor(bounds.top+(bounds.bottom-bounds.top)*0.8),x,Math.floor(bounds.top+(bounds.bottom-bounds.top)*0.3),600);
                  await driver.delayMs(300);marker=await driver.findComponent(ON.text('RIGHT EDGE'));
                }
                if(marker!==null) {
                  const edge=await marker.getBounds();
                  if(edge.right>bounds.right+2||edge.left<bounds.left-2) result.error='Newsletter right edge clipped';
                } else { result.error='Newsletter right edge not visible'; }
              }
              await delegator.executeShellCommand(`uitest screenCap -p /data/local/tmp/corpus-${fixture.uid}-body.png`);
            }
          } catch(error) { result.error=(error as Error).message; }
          results.push(result);
          // Preserve completed cases even if a later platform UI call times out.
          const progress=http.createHttp();
          try {await progress.request('http://localhost:9760/corpus/result',{method:http.RequestMethod.POST,extraData:JSON.stringify(results)});} finally {progress.destroy();}
          if(opened) { await driver.pressBack();await driver.delayMs(250); }
        }
        const report=http.createHttp();
        try {await report.request('http://localhost:9760/corpus/result',{method:http.RequestMethod.POST,extraData:JSON.stringify(results)});} finally {report.destroy();}
        console.info(`CORPUS_RESULTS ${JSON.stringify(results)}`);
        expect(results.filter(value=>value.error!=='').map(value=>`${value.name}: ${value.error}`).join('; ')).assertEqual('');
      } finally {
        await ability.context.terminateSelf();for(const account of await store.list()) await store.remove(account.id);
        await store.close();await delegator.removeAbilityMonitor(monitor);
      }
    });
    }
  });
}
