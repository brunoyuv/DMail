import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
@Entry
@Component
struct AccountFixture {
  build() {
    Column() {
      ConnectedMail({ accountStore: new AccountStore('imap_ui_test.db'), protocol: 'imap',
        serverUrl: 'localhost', port: '9761', username: 'account', emailAddress: 'reader@example.test', token: 'fixture-password' })
    }.height('100%').width('100%')
  }
}
