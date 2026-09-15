// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { ConnectedMail } from '../../../main/ets/pages/ConnectedMail';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { JmapClientFactory, JmapCredentials, JmapService } from '../../../main/ets/mail/jmap/JmapClient';
import { JmapClient } from '../support/PrototypeJmapClient';
import { FixtureTransport } from '../test/Jmap.test';

// Historical UI fixture uses the test-only protocol engine. Production uses Swift.
class FixtureClientFactory implements JmapClientFactory {
  create(sessionUrl: string, credentials: JmapCredentials): JmapService {
    return new JmapClient(sessionUrl, new FixtureTransport(), credentials);
  }
}

@Entry
@Component
struct AccountFixture {
  build() {
    Column() {
      ConnectedMail({ clientFactory: new FixtureClientFactory(), accountStore: new AccountStore('thunderbird_ui_test.db'),
        protocol: 'jmap', serverUrl: 'https://fixture.example/session', token: 'fixture-only-token' })
    }.width('100%').height('100%')
  }
}
