// Synthetic failed data images only. No account, endpoint, or network access.
import { HtmlMail } from '../../../main/ets/pages/HtmlMail';

@Entry
@Component
struct HtmlImageSizingFixture {
  @State private authoredHeight: boolean = false;
  private readonly logo: string = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAPAAAABICAIAAABHru/dAAABfUlEQVR4nO3SQQ0CAQDEwDPDl/BEEDZQhBWMoAI88OleMk0lzPG5XU73/fU43dfn+3R/T9iR6wR69hrnPwENNND1uU6gZwMaaKDrc51AzwY00EDX5zqBng1ooIGuz3UCPRvQQANdn+sEejaggQa6PtcJ9GxAAw10fa4T6NmABhro+lwn0LMBDTTQ9blOoGcDGmig63OdQM8GNNBA1+c6gZ4NaKCBrs91Aj0b0EADXZ/rBHo2oIEGuj7XCfRsQAMNdH2uE+jZgAYa6PpcJ9CzAQ000PW5TqBnAxpooOtznUDPBjTQQNfnOoGeDWigga7PdQI9G9BAA12f6wR6NqCBBro+1wn0bEADDXR9rhPo2YAGGuj6XCfQswENNND1uU6gZwMaaKDrc51AzwY00EDX5zqBng1ooIGuz3UCPRvQQANdn+sEejaggQa6PtcJ9GxAAw10fa4T6NmABhro+lwn0LMBDTTQ9blOoGcDGmig63OdQM8GNNBA1+c6gZ7tBwUTsLzbhwADAAAAAElFTkSuQmCC';
  private document(): string {
    const failed = 'data:image/png;base64,AA==';
    const override = this.authoredHeight ? '<style>.sizing-tiny{height:1px!important}.sizing-visible{height:80px!important}</style>' : '';
    return '<style>.sizing-case{border-bottom:1px solid #ddd;padding:0 0 8px;margin:0 0 8px}' +
      '.sizing-label{font:14px/20px sans-serif;margin:0 0 4px}.sizing-line{text-align:center;margin:0;min-height:0}' +
      '.sizing-heading{font:20px/26px sans-serif;margin:8px 0}</style>' + override +
      `<p class="sizing-line"><img src="${this.logo}" width="120" height="36" alt="Valid inline logo"></p>` +
      '<h2 class="sizing-heading">Synthetic newsletter</h2>' +
      `<p class="sizing-label">HTML: ${this.authoredHeight ? 'authored heights' : 'current renderer'}</p>` +
      '<div class="sizing-case"><p class="sizing-label">1. HTML width 1, height 1</p>' +
      `<p class="sizing-line"><img id="sizing-1" class="sizing-tiny" src="${failed}" width="1" height="1"></p></div>` +
      '<div class="sizing-case"><p class="sizing-label">2. HTML height 1, width omitted</p>' +
      `<p class="sizing-line"><img id="sizing-2" class="sizing-tiny" src="${failed}" height="1"></p></div>` +
      '<div class="sizing-case"><p class="sizing-label">3. Inline style width 1px, height 1px</p>' +
      `<p class="sizing-line"><img id="sizing-3" class="sizing-tiny" src="${failed}" style="width:1px;height:1px"></p></div>` +
      '<div class="sizing-case"><p class="sizing-label">4. Visible failed image 120 x 80</p>' +
      `<p class="sizing-line"><img id="sizing-4" class="sizing-visible" src="${failed}" width="120" height="80" alt="Visible missing image"></p></div>` +
      '<p class="sizing-label">SIZING END</p>';
  }
  build() {
    Column() {
      Text('Synthetic image sizing').id('html-image-sizing-fixture').fontSize(17).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.mail_text_primary')).padding({ left: 16, right: 16, top: 12, bottom: 4 }).width('100%')
      Row({ space: 8 }) {
        Text(this.authoredHeight ? 'Authored heights' : 'Current renderer').id('html-image-sizing-mode')
          .fontSize(14).fontColor($r('app.color.mail_text_primary')).layoutWeight(1)
        Button('Preserve heights').id('html-image-sizing-compare').height(44)
          .onClick(() => { this.authoredHeight = true; })
      }.padding({ left: 16, right: 16, bottom: 8 }).width('100%')
      Scroll() {
        HtmlMail({ html: this.document(), messageKey: 'synthetic-image-sizing', fitContent: true, contentInset: 20 }).width('100%')
      }.id('html-image-sizing-scroll').width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
