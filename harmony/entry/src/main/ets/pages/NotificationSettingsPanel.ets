// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { AccountStore } from '../data/AccountStore';
import { FOREGROUND_MINUTES, BACKGROUND_MINUTES, NotificationAccountState } from '../mail/notifications/NotificationModel';
import { NotificationPlatform } from '../mail/notifications/NotificationPlatform';
import { MailNotificationService } from '../mail/notifications/MailNotificationService';

@Component
export struct NotificationSettingsPanel {
  @Prop @Watch('reload') accountId: string = '';
  store: AccountStore = new AccountStore();
  @StorageLink('mailNotificationSettingsRevision') @Watch('reload') private settingsRevision: number = 0;
  @StorageLink('mailInboxUpdateRevision') @Watch('refreshSystem') private foregroundRevision: number = 0;
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private notificationsOn: boolean = false;
  @State private foregroundMinutes: number = 5;
  @State private backgroundMinutes: number = 120;
  @State private systemEnabled: boolean = true;
  @State private bannerBlocked: boolean = false;
  @State private badgeBlocked: boolean = false;
  @State private testSent: boolean = false;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  private active: boolean = false;
  private revision: number = 0;
  aboutToAppear(): void { this.active = true; this.reload(); }
  aboutToDisappear(): void { this.active = false; ++this.revision; }
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private apply(value: NotificationAccountState): void {
    this.notificationsOn = value.enabled; this.foregroundMinutes = value.foregroundMinutes; this.backgroundMinutes = value.backgroundMinutes;
  }
  private async reload(): Promise<void> {
    const revision = ++this.revision, accountId = this.accountId;
    this.ready = false; this.busy = false; this.failed = false; this.notificationsOn = false;
    if (!accountId) { return; }
    try {
      const value = await this.store.notificationSettings(accountId);
      if (this.active && revision === this.revision) { this.apply(value); this.ready = true; this.refreshSystem(); }
    } catch (_) { if (this.active && revision === this.revision) { this.failed = true; } }
  }
  private async refreshSystem(): Promise<void> {
    const revision = this.revision;
    try {
      const status = await NotificationPlatform.settings();
      if (!this.active || revision !== this.revision) { return; }
      this.systemEnabled = status.enabled;
      this.bannerBlocked = status.bannerEnabled === false || status.slotEnabled === false;
      this.badgeBlocked = status.badgeEnabled === false;
    } catch (_) {}
  }
  private async openSystemSettings(): Promise<void> {
    try { await NotificationPlatform.openSettings(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    catch (_) { this.failed = true; }
    finally { this.refreshSystem(); }
  }
  private async testNotification(): Promise<void> {
    if (this.busy || !this.ready) { return; }
    const revision = this.revision, accountId = this.accountId;
    this.busy = true; this.failed = false; this.testSent = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await NotificationPlatform.requestEnable(context);
      await NotificationPlatform.publish(context, 2147483000, accountId);
      if (this.active && revision === this.revision) { this.testSent = true; }
    } catch (_) { if (this.active && revision === this.revision) { this.failed = true; } }
    finally {
      if (this.active && revision === this.revision) { this.busy = false; this.refreshSystem(); }
    }
  }
  private async recover(accountId: string, revision: number): Promise<void> {
    try {
      const value = await this.store.notificationSettings(accountId);
      if (this.active && revision === this.revision) { this.apply(value); }
    } catch (_) {}
    if (this.active && revision === this.revision) { this.failed = true; }
  }
  private updateScheduler(context: common.UIAbilityContext, revision: number): void {
    // Reconciliation may establish a server baseline. Keep the settings and
    // account picker responsive while that independent work is in progress.
    AppStorage.setOrCreate('mailNotificationSettingsRevision', (AppStorage.get<number>('mailNotificationSettingsRevision') || 0) + 1);
    this.refreshSystem();
    MailNotificationService.settingsChanged(context).catch(() => {
      if (this.active && revision === this.revision) { this.failed = true; }
    });
  }
  private async changeEnabled(enabled: boolean): Promise<void> {
    if (!this.ready || this.busy || enabled === this.notificationsOn) { return; }
    const accountId = this.accountId, revision = ++this.revision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true; this.failed = false;
    try {
      // Permission UI is reached only through this explicit user interaction.
      // The account stays disabled until OS permission has been granted.
      if (enabled) { await NotificationPlatform.requestEnable(context); }
      await this.store.setNotifications(accountId, enabled);
      const value = await this.store.notificationSettings(accountId);
      if (!enabled) { await NotificationPlatform.cancel(value.notificationId); }
      if (this.active && revision === this.revision) { this.apply(value); }
    } catch (_) { await this.recover(accountId, revision); }
    finally {
      this.updateScheduler(context, revision);
      if (this.active && revision === this.revision) { this.busy = false; }
    }
  }
  private async changeFrequency(foreground: number, background: number): Promise<void> {
    if (!this.ready || this.busy || !this.notificationsOn) { return; }
    const accountId = this.accountId, revision = ++this.revision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true; this.failed = false;
    try {
      await this.store.notifications.frequencies(accountId, foreground, background);
      const value = await this.store.notificationSettings(accountId);
      if (this.active && revision === this.revision) { this.apply(value); }
    } catch (_) { await this.recover(accountId, revision); }
    finally {
      this.updateScheduler(context, revision);
      if (this.active && revision === this.revision) { this.busy = false; }
    }
  }
  private async retrySettings(): Promise<void> {
    if (this.busy) { return; }
    const accountId = this.accountId, revision = ++this.revision;
    this.busy = true; this.failed = false;
    try {
      const value = await this.store.notificationSettings(accountId);
      if (this.active && revision === this.revision) { this.apply(value); this.ready = true; }
    } catch (_) { await this.recover(accountId, revision); }
    finally {
      this.updateScheduler(this.getUIContext().getHostContext() as common.UIAbilityContext, revision);
      if (this.active && revision === this.revision) { this.busy = false; }
    }
  }
  build() {
    Column({ space: 12 }) {
      Text(this.label('mail_notifications')).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
        .fontColor($r('app.color.mail_text_primary'))
      Row({ space: 12 }) {
        Text(this.label('new_mail_alerts')).fontSize(17).layoutWeight(1).fontColor($r('app.color.mail_text_primary'))
        Toggle({ type: ToggleType.Switch, isOn: this.notificationsOn }).id('notifications-enabled')
          .enabled(this.ready && !this.busy).onChange(value => this.changeEnabled(value))
      }.width('100%').constraintSize({ minHeight: 48 })
      if (this.notificationsOn) {
        Text(this.label('notification_foreground_interval')).fontSize(15).width('100%').fontColor($r('app.color.mail_text_secondary'))
        Select(FOREGROUND_MINUTES.map((value: number): SelectOption => {
          const option: SelectOption = { value: this.label(`notification_minutes_${value}`) }; return option;
        }))
          .id('notification-foreground-frequency').width('100%')
          .selected(FOREGROUND_MINUTES.indexOf(this.foregroundMinutes)).value(this.label(`notification_minutes_${this.foregroundMinutes}`))
          .enabled(this.ready && !this.busy).onSelect(index => {
            if (FOREGROUND_MINUTES[index]) { this.changeFrequency(FOREGROUND_MINUTES[index], this.backgroundMinutes); }
          })
        Text(this.label('notification_background_interval')).fontSize(15).width('100%').fontColor($r('app.color.mail_text_secondary'))
        Select(BACKGROUND_MINUTES.map((value: number): SelectOption => {
          const option: SelectOption = { value: this.label(`notification_minutes_${value}`) }; return option;
        }))
          .id('notification-background-frequency').width('100%')
          .selected(BACKGROUND_MINUTES.indexOf(this.backgroundMinutes)).value(this.label(`notification_minutes_${this.backgroundMinutes}`))
          .enabled(this.ready && !this.busy).onSelect(index => {
            if (BACKGROUND_MINUTES[index]) { this.changeFrequency(this.foregroundMinutes, BACKGROUND_MINUTES[index]); }
          })
      }
      if (!this.systemEnabled || this.bannerBlocked || this.badgeBlocked) {
        Text(this.label(!this.systemEnabled ? 'notification_system_blocked' : this.bannerBlocked ? 'notification_banner_blocked' : 'notification_badge_blocked'))
          .id('notification-system-status').fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      }
      Button(this.label('notification_system_settings')).id('open-system-notification-settings')
        .buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => this.openSystemSettings())
      Button(this.label('notification_test')).id('test-notification').enabled(this.ready && !this.busy)
        .buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.testNotification())
      if (this.testSent) {
        Text(this.label('notification_test_sent')).id('notification-test-sent').fontSize(14).width('100%')
          .fontColor($r('app.color.mail_text_secondary'))
      }
      Text(this.label('notification_foreground_help')).fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      Text(this.label('notification_background_help')).fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      Text(this.label('notification_baseline_help')).fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      if (this.failed) {
        Text(this.label('notification_settings_error')).id('notification-settings-error').fontSize(14).width('100%')
          .fontColor($r('app.color.mail_text_secondary'))
        Button(this.label('retry')).id('retry-notification-settings').buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(!this.busy).onClick(() => this.retrySettings())
      }
    }.id('notification-settings').width('100%').alignItems(HorizontalAlign.Start)
  }
}
