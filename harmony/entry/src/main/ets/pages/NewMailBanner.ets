// MPL-2.0: https://mozilla.org/MPL/2.0/
import { MailBannerNotice } from '../mail/notifications/MailBannerNotice';
import { MailInboxUpdates } from '../mail/notifications/MailInboxUpdates';

@Component
export struct NewMailBanner {
  @StorageLink('mailBannerRevision') @Watch('changed') private revision: number = 0;
  @StorageLink('mailInboxUpdateRevision') @Watch('changed') private inboxRevision: number = 0;
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private visible: boolean = false;
  private timer: number = -1;
  aboutToAppear(): void { this.changed(); }
  aboutToDisappear(): void { if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; } }
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private changed(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    const remaining = 7000 - (Date.now() - (AppStorage.get<number>('mailBannerAt') || 0));
    this.visible = MailInboxUpdates.isForeground() && remaining > 0 && !!AppStorage.get<string>('mailBannerAccountId');
    if (this.visible) { this.timer = setTimeout(() => { this.timer = -1; this.visible = false; }, remaining); }
  }
  build() {
    if (this.visible) {
      Row({ space: 8 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.envelope')).fontSize(24).fontColor([$r('app.color.mail_accent')])
            Column({ space: 2 }) {
              Text(this.label('new_mail_notification_title')).fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.mail_text_primary')).width('100%')
              Text(this.label('new_mail_notification_text')).fontSize(13)
                .fontColor($r('app.color.mail_text_secondary')).width('100%')
            }.layoutWeight(1)
          }.width('100%')
        }.id('new-mail-banner-open').layoutWeight(1).padding(12).backgroundColor(Color.Transparent)
          .onClick(() => MailBannerNotice.open())
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([$r('app.color.mail_text_secondary')])
        }.id('new-mail-banner-dismiss').width(36).height(36).margin({ right: 8 })
          .backgroundColor(Color.Transparent).accessibilityText(this.label('dismiss_notification'))
          .onClick(() => MailBannerNotice.dismiss())
      }.id('new-mail-banner').width('100%').constraintSize({ maxWidth: 520 }).borderRadius(18)
        .backgroundColor($r('app.color.mail_surface')).shadow({ radius: 14, color: '#22000000', offsetY: 4 })
        .margin({ top: 12, left: 16, right: 16 })
    }
  }
}
