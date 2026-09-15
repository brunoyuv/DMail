import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
@Entry
@Component
struct MailboxFixture {
  build() {
    Column() {
      ConnectedMail({ accountStore: new AccountStore('imap_gestures_test.db'), openInboxOnLaunch: true })
    }.height('100%').width('100%')
  }
}
