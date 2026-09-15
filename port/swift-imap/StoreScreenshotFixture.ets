// Test-only host: the shipping UI, with an in-memory service and fictional data.
import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NavigationClientFactory } from '../support/NavigationClient';

@Entry
@Component
struct StoreScreenshotFixture {
  build() {
    Column() {
      ConnectedMail({ accountStore: new AccountStore('navigation_ui_test.db'),
        clientFactory: new NavigationClientFactory(), openInboxOnLaunch: true })
        .width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
