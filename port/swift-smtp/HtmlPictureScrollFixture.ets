// Long synthetic picture mail uses the production reader wrappers in both modes.
import { HtmlMail } from '../pages/HtmlMail';
import { HtmlMail018 } from '../pages/HtmlMail018';
import { HtmlPictureScrollState } from '../support/HtmlPictureScrollState';
import { HtmlScrollPowerState } from '../support/HtmlScrollPowerState';

@Entry
@Component
struct HtmlPictureScrollFixture {
  @State private closed: boolean = false;
  private readonly mode: string = HtmlScrollPowerState.mode;
  private readonly scene: number = HtmlScrollPowerState.scene;
  private readonly html: string = HtmlPictureScrollState.document();
  private readonly scroller: Scroller = new Scroller();
  aboutToAppear(): void { HtmlScrollPowerState.setActive(this.scene, true); }
  aboutToDisappear(): void { HtmlScrollPowerState.setActive(this.scene, false); }
  build() {
    Column() {
      Row() {
        Text('Synthetic picture scroll check').id('html-power-fixture').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.mail_text_primary')).layoutWeight(1)
        Button('Close').id('html-power-close').height(44)
          .onClick(() => {
            HtmlPictureScrollState.recordCloseTap(this.scene);
            HtmlScrollPowerState.setActive(this.scene, false); this.closed = true;
          })
      }.padding(16).width('100%')
      if (this.closed) {
        Text('Synthetic email closed').id('html-power-closed').fontSize(18).padding(20)
          .onAppear(() => HtmlPictureScrollState.recordCloseVisible(this.scene))
      } else {
        Scroll(this.scroller) {
          Column() {
            Column() {
              Text('Synthetic sender • reader@example.test').fontSize(14).padding({ bottom: 8 }).width('100%')
              if (this.mode === 'baseline018') {
                HtmlMail018({ html: this.html, pictureCache: HtmlPictureScrollState.cache, accountId: 'synthetic-scroll', messageKey: 'synthetic-picture-message', fitContent: true, contentInset: 0 }).width('100%')
              } else {
                HtmlMail({ html: this.html, pictureCache: HtmlPictureScrollState.cache, accountId: 'synthetic-scroll', messageKey: 'synthetic-picture-message', fitContent: true, contentInset: 0 }).width('100%')
              }
            }.width('100%')
          }.id('html-power-reader-column').width('100%').constraintSize({ maxWidth: 760 })
            .padding({ left: 20, right: 20, top: 10, bottom: 24 })
        }.id('html-power-scroll').width('100%').layoutWeight(1).align(Alignment.Top)
          .onDidScroll(() => {
            HtmlScrollPowerState.recordScroll(this.mode, this.scene, this.scroller.currentOffset().yOffset);
          })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
