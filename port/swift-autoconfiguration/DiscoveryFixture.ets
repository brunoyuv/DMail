import { discoveryRequest } from 'libthunderbird.so';
import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { MailConfiguration, MailDiscoveryService } from '../../../main/ets/mail/discovery/NativeMailDiscovery';

export const configurationXml: string = `<clientConfig version="1.1"><emailProvider id="example.test">
<domain>example.test</domain><displayName>Example Mail</displayName><displayShortName>Example</displayShortName>
<incomingServer type="imap"><hostname>localhost</hostname><port>9761</port><socketType>SSL</socketType>
<username>%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></incomingServer>
<outgoingServer type="smtp"><hostname>localhost</hostname><port>9772</port><socketType>STARTTLS</socketType>
<username>smtp-%EMAILLOCALPART%</username><authentication>password-cleartext</authentication></outgoingServer>
</emailProvider></clientConfig>`;
interface ParseRequest { operation: string; email: string; document: string; }
interface ParseReply { configuration: MailConfiguration; }
export class FixtureDiscovery implements MailDiscoveryService {
  async discover(email: string): Promise<MailConfiguration> {
    const input: ParseRequest = { operation: 'parse', email, document: configurationXml };
    return (JSON.parse(await discoveryRequest(JSON.stringify(input))) as ParseReply).configuration;
  }
}
@Entry
@Component
struct DiscoveryFixture {
  build() {
    Column() {
      ConnectedMail({ accountStore: new AccountStore('discovery_ui_test.db'),
        discoveryService: new FixtureDiscovery(), emailAddress: 'account@example.test', token: 'fixture-password' })
    }.height('100%').width('100%')
  }
}
