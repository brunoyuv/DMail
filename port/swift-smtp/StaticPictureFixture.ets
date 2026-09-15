// Synthetic static-document gate, using the shipping reader and encrypted cache.
import { HtmlMail } from '../pages/HtmlMail';
import { StaticPictureState } from '../support/StaticPictureState';

@Entry
@Component
struct StaticPictureFixture {
  private readonly scene: number = StaticPictureState.scene;
  private readonly html: string = StaticPictureState.savedBody;
  private readonly scroller: Scroller = new Scroller();
  aboutToAppear(): void {
    StaticPictureState.setActive(this.scene, true);
    StaticPictureState.setScrollTop(this.scene, (): void => { this.scroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false }); });
  }
  aboutToDisappear(): void { StaticPictureState.setActive(this.scene, false); }
  build() {
    Column() {
      Text('Synthetic static picture check').id('static-picture-fixture').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.mail_text_primary')).padding(16).width('100%')
      Scroll(this.scroller) {
        Column() {
          Text('Synthetic sender • reader@example.test').fontSize(14).padding({ bottom: 16 }).width('100%')
          HtmlMail({ html: this.html, accountId: StaticPictureState.accountId, messageKey: StaticPictureState.messageKey,
            pictureCache: StaticPictureState.cache, savedDocument: StaticPictureState.savedDocument, fitContent: true, contentInset: 0 }).width('100%')
        }.width('100%').constraintSize({ maxWidth: 760 }).padding({ left: 20, right: 20, top: 10, bottom: 24 })
      }.id('static-picture-scroll').width('100%').layoutWeight(1).align(Alignment.Top)
        .onDidScroll(() => StaticPictureState.recordScroll(this.scene, this.scroller.currentOffset().yOffset))
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
