// One mounted production renderer, identical synthetic HTML, different messages.
import { HtmlMail } from '../../../main/ets/pages/HtmlMail';

@Entry
@Component
struct HtmlConsentFixture {
  @State private messageKey: string = 'consent-a';
  private readonly html: string = '<p>Identical synthetic message body.</p><img src="http://localhost:9770/picture.png" alt="Synthetic remote picture" width="80" height="80">';

  build() {
    Column() {
      Row({ space: 12 }) {
        Text(this.messageKey).id('consent-message-key').layoutWeight(1)
        Button('Switch message').id('switch-consent-message').height(44)
          .onClick(() => { this.messageKey = 'consent-b'; })
      }.width('100%').padding(16)
      // Do not put this in a conditional or ForEach: changing only the identity
      // must revoke permission on the existing component, not recreate it.
      HtmlMail({ html: this.html, messageKey: this.messageKey })
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('sys.color.background_primary'))
  }
}
