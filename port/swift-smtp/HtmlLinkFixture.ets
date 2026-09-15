// Actual shipping ArkWeb renderer; links are intercepted by a test-only opener.
import { HtmlMail } from '../pages/HtmlMail';
import { HtmlLinkState } from '../support/HtmlLinkState';
import { PreparedMailDocument } from '../data/PreparedDocumentModel';
import { prepareStaticMailHtml } from '../mail/html/HtmlPicturePlan';
import { preparedMailDocument } from '../mail/html/HtmlDocument';

// Prepare the synthetic sync result before mounting the reader, as production
// does during mailbox sync. Link tests never ask the reader to scan raw HTML.
function savedLinkDocument(): PreparedMailDocument {
  const plan = prepareStaticMailHtml(HtmlLinkState.document());
  return { version: 1, messageKey: 'synthetic-link-email', bodySavedAt: Date.now(), savedAt: Date.now(),
    html: preparedMailDocument(plan.html, false, 0), pictures: plan.pictures };
}

@Entry
@Component
struct HtmlLinkFixture {
  @State private closed: boolean = false;
  private readonly savedDocument: PreparedMailDocument = savedLinkDocument();
  private readonly scene: number = HtmlLinkState.scene;
  private readonly scroller: Scroller = new Scroller();
  aboutToAppear(): void { HtmlLinkState.setActive(this.scene, true); }
  aboutToDisappear(): void { HtmlLinkState.setActive(this.scene, false); }
  build() {
    Column() {
      Row() {
        Text('Synthetic link check').id('html-link-fixture').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.mail_text_primary')).layoutWeight(1)
        Button('Close').id('html-link-close').height(44)
          .onClick(() => { HtmlLinkState.setActive(this.scene, false); this.closed = true; })
      }.padding(16).width('100%')
      if (this.closed) {
        Text('Synthetic email closed').id('html-link-closed').fontSize(18).padding(20)
      } else {
        Scroll(this.scroller) {
          // Match the shipping reader's intrinsic Column wrappers and gutters.
          // No spacer or artificial content height supplies scrolling proof.
          Column() {
            Column() {
              Text('Synthetic sender • reader@example.test').fontSize(14).padding({ bottom: 8 }).width('100%')
              HtmlMail({ savedDocument: this.savedDocument, messageKey: 'synthetic-link-email', fitContent: true, contentInset: 0,
                openLink: async (url: string): Promise<void> => { await HtmlLinkState.open(url); } }).width('100%')
            }.width('100%')
          }.id('html-link-reader-column').width('100%').constraintSize({ maxWidth: 760 })
            .padding({ left: 20, right: 20, top: 10, bottom: 24 })
        }.id('html-link-scroll').width('100%').layoutWeight(1).align(Alignment.Top)
          .onDidScroll((_x: number, y: number, _state: ScrollState) => {
            HtmlLinkState.recordScroll(this.scene, this.scroller.currentOffset().yOffset, y);
          })
      }
    }.width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
  }
}
