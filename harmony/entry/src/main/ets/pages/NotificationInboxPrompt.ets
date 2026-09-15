// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { AccountStore } from '../data/AccountStore';
import { NotificationPlatform } from '../mail/notifications/NotificationPlatform';
import { MailNotificationService } from '../mail/notifications/MailNotificationService';
import { MailInboxUpdates } from '../mail/notifications/MailInboxUpdates';

@Component
export struct NotificationInboxPrompt {
  @Prop @Watch('reload') accountId: string = '';
  store: AccountStore = new AccountStore();
  @StorageLink('mailNotificationSettingsRevision') @Watch('reload') private settingsRevision: number = 0;
  @StorageLink('mailInboxUpdateRevision') @Watch('foregroundChanged') private foregroundRevision: number = 0;
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private visible: boolean = false;
  @State private blocked: boolean = false;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  private active: boolean = false;
  private revision: number = 0;
  private foreground: boolean = false;
  aboutToAppear(): void { this.active = true; this.foreground = MailInboxUpdates.isForeground(); this.reload(); }
  aboutToDisappear(): void { this.active = false; ++this.revision; }
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private foregroundChanged(): void {
    const foreground = MailInboxUpdates.isForeground();
    if (foreground === this.foreground) { return; }
    this.foreground = foreground;
    if (foreground && this.active) { this.reload(); }
  }
  private async reload(): Promise<void> {
    if (!this.active) { return; }
    const revision = ++this.revision, accountId = this.accountId;
    if (this.busy || !accountId) { this.visible = false; return; }
    try {
      const value = await this.store.notificationSettings(accountId);
      const system = await NotificationPlatform.settings();
      if (!this.active || revision !== this.revision) { return; }
      this.blocked = value.enabled && (!system.enabled || system.bannerEnabled === false || system.slotEnabled === false);
      // Respect an account the user explicitly disabled; only offer first enable
      // or explain an enabled account whose OS delivery has been switched off.
      this.visible = value.notificationId === 0 || this.blocked;
    } catch (_) { /* Settings remain reachable from Mailboxes. */ }
  }
  private async activate(): Promise<void> {
    if (this.busy || !this.accountId) { return; }
    const accountId = this.accountId, context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true; this.failed = false;
    try {
      if (this.blocked) { await NotificationPlatform.openSettings(context); }
      else {
        await NotificationPlatform.requestEnable(context);
        await this.store.setNotifications(accountId, true);
        MailNotificationService.settingsChanged(context).catch(() => {});
        AppStorage.setOrCreate('mailNotificationSettingsRevision', (AppStorage.get<number>('mailNotificationSettingsRevision') || 0) + 1);
      }
    } catch (_) {
      // A denied permission cannot be requested again. Offer the actual system
      // settings screen on the next tap instead of retrying the same dialog.
      if (this.active && this.accountId === accountId) { this.failed = true; this.blocked = true; }
    } finally {
      this.busy = false;
      if (this.active) {
        if (this.accountId !== accountId) { this.failed = false; await this.reload(); }
        else if (!this.failed) { await this.reload(); }
        else { this.visible = true; }
      }
    }
  }
  build() {
    if (this.visible) {
      Row({ space: 8 }) {
        Text(this.label(this.failed ? 'notification_settings_error' : this.blocked ? 'notification_banner_blocked' : 'notification_inbox_offer'))
          .fontSize(13).fontColor($r('app.color.mail_text_secondary')).layoutWeight(1)
        Button(this.label(this.blocked ? 'notification_system_settings' : 'notification_enable'), { type: ButtonType.Capsule })
          .id(this.blocked ? 'open-inbox-notification-settings' : 'enable-inbox-notifications')
          .fontSize(13).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.busy).onClick(() => this.activate())
      }.id('inbox-notification-prompt').width('100%').padding({ left: 20, right: 12, bottom: 6 })
    }
  }
}
