import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NavigationClientFactory } from '../support/NavigationClient';
import { NewMailBanner } from '../../../main/ets/pages/NewMailBanner';

@Entry
@Component
struct NavigationFixture {
  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        Text('Synthetic preview layout check').id('navigation-fixture-marker').fontSize(10).height(18)
          .fontColor($r('app.color.mail_text_secondary')).width('100%')
        ConnectedMail({ accountStore: new AccountStore('navigation_ui_test.db'),
          clientFactory: new NavigationClientFactory(), openInboxOnLaunch: true })
          .width('100%').layoutWeight(1)
      }.width('100%').height('100%')
      NewMailBanner()
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
