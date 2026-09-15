// Main-HAP host for the synthetic large-Inbox review gate.
import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { NavigationClientFactory } from '../support/NavigationClient';

@Entry
@Component
struct ReviewInboxFixture {
  private store: AccountStore = new AccountStore('navigation_ui_test.db');
  private clients: NavigationClientFactory = new NavigationClientFactory();
  build() {
    Column() {
      Text('Synthetic 2000-header Inbox review').id('review-inbox-fixture-marker').fontSize(10).height(18)
        .fontColor($r('app.color.mail_text_secondary')).width('100%')
      ConnectedMail({ accountStore: this.store, clientFactory: this.clients, openInboxOnLaunch: true })
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
