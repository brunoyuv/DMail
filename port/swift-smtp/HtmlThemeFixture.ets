// Synthetic content only; never connect a mail account in this diagnostic.
import { HtmlMail } from '../../../main/ets/pages/HtmlMail';

@Entry
@Component
struct HtmlThemeFixture {
  @State private forward: boolean = false;
  private readonly html: string = '<table bgcolor="#ffffff" style="background:#fff;color:#000;padding:16px;width:100%"><tr><td>' +
    '<h2 style="margin:0 0 12px">Authored white panel</h2><p>Current reply — café 中文 日本語.</p>' +
    '<p>Sender HTML uses a white table and black text.</p>' +
    '<img width="240" height="72" alt="Synthetic original color picture" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAPAAAABICAIAAABHru/dAAABfUlEQVR4nO3SQQ0CAQDEwDPDl/BEEDZQhBWMoAI88OleMk0lzPG5XU73/fU43dfn+3R/T9iR6wR69hrnPwENNND1uU6gZwMaaKDrc51AzwY00EDX5zqBng1ooIGuz3UCPRvQQANdn+sEejaggQa6PtcJ9GxAAw10fa4T6NmABhro+lwn0LMBDTTQ9blOoGcDGmig63OdQM8GNNBA1+c6gZ4NaKCBrs91Aj0b0EADXZ/rBHo2oIEGuj7XCfRsQAMNdH2uE+jZgAYa6PpcJ9CzAQ000PW5TqBnAxpooOtznUDPBjTQQNfnOoGeDWigga7PdQI9G9BAA12f6wR6NqCBBro+1wn0bEADDXR9rhPo2YAGGuj6XCfQswENNND1uU6gZwMaaKDrc51AzwY00EDX5zqBng1ooIGuz3UCPRvQQANdn+sEejaggQa6PtcJ9GxAAw10fa4T6NmABhro+lwn0LMBDTTQ9blOoGcDGmig63OdQM8GNNBA1+c6gZ7tBwUTsLzbhwADAAAAAElFTkSuQmCC">' +
    '</td></tr></table><blockquote style="background:white;color:black"><p>Earlier answer in blue.</p>' +
    '<blockquote style="background:#fff;color:#000"><p>Older answer in green.</p><blockquote><p>Original question in purple.</p></blockquote></blockquote></blockquote>';
  build() {
    Column() {
      Text('Synthetic HTML theme check').id('html-theme-fixture').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.mail_text_primary')).padding(16).width('100%')
      Row({ space: 12 }) {
        Text(this.forward ? 'Forward preview' : 'Conversation reply').id('html-theme-layout').fontSize(16)
          .fontColor($r('app.color.mail_text_primary')).layoutWeight(1)
        Button('Forward layout').id('html-theme-forward').height(44).onClick(() => { this.forward = true; })
      }.padding({ left: 16, right: 16, bottom: 12 }).width('100%')
      if (this.forward) {
        Row() {
          Text('To: reader@example.test').fontSize(16).fontColor($r('app.color.mail_text_secondary'))
        }.padding(16).width('100%')
        TextArea({ text: 'Synthetic forwarding note.' }).fontSize(17).height(72).width('100%')
          .backgroundColor(Color.Transparent).padding(16)
      }
      // Both production reader and composer use this same native HTML renderer.
      HtmlMail({ html: this.html, messageKey: 'synthetic-theme-reply', contentInset: this.forward ? 0 : 20 })
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
