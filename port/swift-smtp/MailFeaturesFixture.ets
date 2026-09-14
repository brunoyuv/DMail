import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
@Entry
@Component
struct MailFeaturesFixture {
  build() {
    Column() {
      ConnectedMail({ accountStore: new AccountStore('mail_features_test.db'), openInboxOnLaunch: true })
    }.height('100%').width('100%')
  }
}
