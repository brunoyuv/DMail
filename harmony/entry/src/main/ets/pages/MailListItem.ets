// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { JmapEmail } from '../mail/jmap/JmapClient';
import { AppLanguage } from '../settings/AppLanguage';

// The parent keys rows by displayed content and action identity. Keep this
// immutable header outside @Prop so row layout never deep-copies mail data.
@Component
export struct MailListItem {
  mail?: JmapEmail;
  count: number = 1;
  @Prop compact: boolean = false;
  @Prop connected: boolean = false;
  @Prop readAllowed: boolean = false;
  @Prop starAllowed: boolean = false;
  @Prop archiveAllowed: boolean = false;
  @Prop mailAction: string = 'archive';
  @StorageLink('appLanguageRevision') @Watch('updateDate') private languageRevision: number = 0;
  @State private contentHeight: number = 0;
  private senderText: string = '';
  private previewText: string = '';
  @State private dateText: string = '';
  onReadFlag: () => void = () => {};
  onStar: () => void = () => {};
  onArchive: () => void = () => {};
  onOpen: () => void = () => {};
  onSwipeOffset: (offset: number) => void = () => {};

  aboutToAppear(): void {
    // Header content is fixed for this keyed row. Layout and scrolling only
    // reuse these strings; they never format sender/preview/date text again.
    if (!this.mail) { return; }
    this.senderText = this.mail.from.map(address => address.name || address.email).join(', ');
    this.previewText = this.mail.preview.replace(/\s+/g, ' ');
    this.updateDate();
  }

  private updateDate(): void {
    if (this.mail) { this.dateText = this.dateLabel(this.mail.receivedAt); }
  }

  private measureHeight(height: number): void {
    // Only this item's marker and swipe panels depend on its measurement.
    if (Number.isFinite(height) && height > 0 && Math.abs(this.contentHeight - height) > 0.5) {
      this.contentHeight = height;
    }
  }

  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }

  private dateLabel(value: number): string {
    this.languageRevision;
    const date = new Date(value);
    return date.toDateString() === new Date().toDateString() ?
      date.toLocaleTimeString(AppLanguage.locale, { hour: '2-digit', minute: '2-digit' }) :
      date.toLocaleDateString(AppLanguage.locale, { month: 'short', day: 'numeric' });
  }

  @Builder
  private swipeRead(mail: JmapEmail) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.envelope')).fontSize(24).fontColor([Color.White])
        Text(this.label(mail.keywords.includes('$seen') ? 'mark_unread' : 'mark_read')).fontSize(13).fontColor(Color.White).maxLines(2).textAlign(TextAlign.Center)
      }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
    }.id(`swipe-read-${mail.id}`).width(88)
      .height(Math.max(44, this.contentHeight))
      .padding(0).borderRadius(0).backgroundColor($r('app.color.mail_accent'))
      .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
      .enabled(this.readAllowed).onClick(() => this.onReadFlag())
  }

  @Builder
  private swipeMore(mail: JmapEmail) {
    Row() {
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          SymbolGlyph(mail.keywords.includes('$flagged') ? $r('sys.symbol.star_fill') : $r('sys.symbol.star')).fontSize(24).fontColor([Color.White])
          Text(this.label(mail.keywords.includes('$flagged') ? 'unstar' : 'star')).fontSize(13).fontColor(Color.White).maxLines(2)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
      }.id(`swipe-star-${mail.id}`).width(76)
        .height(Math.max(44, this.contentHeight))
        .padding(0).borderRadius(0).backgroundColor('#A66B00')
        .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
        .enabled(this.starAllowed).onClick(() => this.onStar())
      Button({ type: ButtonType.Normal }) {
        Column({ space: 6 }) {
          SymbolGlyph(this.mailAction === 'delete' ? $r('sys.symbol.trash') : $r('sys.symbol.folder')).fontSize(24).fontColor([Color.White])
          Text(this.label(this.mailAction)).fontSize(13).fontColor(Color.White).maxLines(2)
        }.width('100%').height('100%').justifyContent(FlexAlign.Center).padding(8)
      }.id(`swipe-archive-${mail.id}`).width(76)
        .height(Math.max(44, this.contentHeight))
        .padding(0).borderRadius(0).backgroundColor(this.mailAction === 'delete' ? '#B3261E' : '#46656A')
        .responseRegion({ x: 0, y: 0, width: '100%', height: '100%' })
        .enabled(this.archiveAllowed)
        .onClick(() => this.onArchive())
    }.height(Math.max(44, this.contentHeight))
  }

  @Builder
  private unreadMarker(mail: JmapEmail) {
    if (!mail.keywords.includes('$seen')) {
      Row().id(`unread-marker-${mail.id}`).width(3)
        .height(Math.max(0, this.contentHeight - (this.compact ? 24 : 32)))
        .borderRadius(2).backgroundColor($r('app.color.mail_accent'))
        .position({ x: 0, y: this.compact ? 12 : 16 })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  @Builder
  private mailRow(mail: JmapEmail) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Text(this.senderText)
            .fontSize(16).lineHeight(19.2).fontWeight((!mail.keywords.includes('$seen')) ? FontWeight.Bold : FontWeight.Medium)
            .fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.dateText).fontSize(12).fontColor($r('app.color.mail_text_secondary'))
        }
        Row({ space: 8 }) {
          Text(mail.subject || this.label('no_subject')).fontSize(16).lineHeight(21.6)
            .fontWeight((!mail.keywords.includes('$seen')) ? FontWeight.Bold : FontWeight.Normal).layoutWeight(1)
            .fontColor($r('app.color.mail_text_primary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.count > 1) {
            Text(`${this.count}`).id(`conversation-count-${mail.id}`).fontSize(12)
              .fontColor($r('app.color.mail_text_secondary')).padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .backgroundColor($r('app.color.mail_surface')).borderRadius(12)
          }
        }.width('100%')
        Row({ space: 6 }) {
          Text(this.previewText).fontSize(14).lineHeight(20.3).fontColor($r('app.color.mail_text_secondary'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (mail.keywords.includes('$flagged')) {
            SymbolGlyph($r('sys.symbol.star')).id(`remote-star-${mail.id}`).fontSize(14).fontColor([$r('app.color.mail_accent')]).margin({ top: 3 })
          }
        }.alignItems(VerticalAlign.Top)
      }.alignItems(HorizontalAlign.Start).width('100%')
        .padding({ top: this.compact ? 12 : 16, bottom: this.compact ? 12 : 16, left: this.compact ? 16 : 20, right: this.compact ? 16 : 20 })
        .onAreaChange((_, area) => { this.measureHeight(Number(area.height)); })
      // A finite height measured from the text cannot expand the row to the
      // list viewport, unlike percentage sizing in an intrinsically sized Stack.
      this.unreadMarker(mail)
    }.width('100%')
    .onClick(() => { this.onOpen(); })
    .accessibilityGroup(true)
    .accessibilityText(`${(!mail.keywords.includes('$seen')) ? `${this.label('unread')}. ` : ''}${this.senderText}. ${mail.subject}. ${mail.keywords.includes('$flagged') ? this.label('starred') : ''}`)
  }

  build() {
    if (this.mail) {
      ListItem() { this.mailRow(this.mail) }
        .id(`remote-mail-${this.mail.id}`).enabled(this.connected)
        .swipeAction({ start: this.swipeRead.bind(this, this.mail), end: this.swipeMore.bind(this, this.mail),
          edgeEffect: SwipeEdgeEffect.None, onOffsetChange: (offset: number) => { this.onSwipeOffset(offset); } })
    }
  }
}
