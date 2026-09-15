// Uses the shipping ArkWeb renderer and persistent picture cache, synthetic only.
import { HtmlMail } from '../pages/HtmlMail';
import { PictureRefreshState } from '../support/PictureRefreshState';

@Entry
@Component
struct PictureRefreshFixture {
  private readonly html: string = '<h2>Synthetic saved pictures</h2><p>Retry only the two missing pictures. Keep the first saved image.</p>' +
    `<div><img src="${PictureRefreshState.url}/good.png" width="240" height="72" alt="Synthetic good colors"></div>` +
    `<div><img src="${PictureRefreshState.url}/connection.png" width="240" height="72" alt="Synthetic connection recovery"></div>` +
    `<div><img src="${PictureRefreshState.url}/server.png" width="240" height="72" alt="Synthetic server recovery"></div>` +
    `<img src="${PictureRefreshState.url}/tracking.gif" width="1" height="1">` +
    `<img src="${PictureRefreshState.url}/hidden.png" style="display:none!important">`;
  build() {
    Column() {
      Text('Synthetic picture refresh check').id('picture-refresh-fixture').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.mail_text_primary')).padding(16).width('100%')
      Scroll() {
        Column() {
          Text('Synthetic sender • reader@example.test').fontSize(14).padding({ bottom: 16 }).width('100%')
          HtmlMail({ html: this.html, accountId: 'synthetic-pictures', messageKey: 'synthetic-message',
            pictureCache: PictureRefreshState.cache, fitContent: true, contentInset: 0 }).width('100%')
          Text('End of synthetic message').fontSize(14).padding({ top: 16 }).width('100%')
        }.width('100%').padding({ left: 20, right: 20 })
      }.width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
