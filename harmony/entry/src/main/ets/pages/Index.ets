// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { ConnectedMail } from './ConnectedMail';
import { NewMailBanner } from './NewMailBanner';

@Entry
@Component
struct Index {
  build() {
    Stack({ alignContent: Alignment.Top }) {
      ConnectedMail({ openInboxOnLaunch: true })
      NewMailBanner()
    }.width('100%').height('100%')
  }
}
