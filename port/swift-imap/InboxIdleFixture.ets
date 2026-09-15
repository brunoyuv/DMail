import { ConnectedMail } from '../pages/ConnectedMail';
import { InboxIdleClientFactory, InboxIdleState } from '../support/InboxIdleState';

@Entry
@Component
struct InboxIdleFixture {
  private clients: InboxIdleClientFactory = new InboxIdleClientFactory();
  build() {
    Column() {
      Text('Synthetic download-on-open check').id('inbox-idle-fixture-marker').fontSize(10).height(18)
        .fontColor($r('app.color.mail_text_secondary')).width('100%')
      Button('Add synthetic arrival').id('inbox-idle-navigation').fontSize(12).height(32)
        .onClick(() => InboxIdleState.advanceNavigation())
      ConnectedMail({ accountStore: InboxIdleState.store, clientFactory: this.clients, openInboxOnLaunch: true })
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
