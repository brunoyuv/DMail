// MPL-2.0: https://mozilla.org/MPL/2.0/
import { MailInboxUpdates } from './MailInboxUpdates';
import { NotificationAccountState } from './NotificationModel';

// Generic foreground notice; no account address or mail content enters AppStorage.
export class MailBannerNotice {
  private static delivered: Map<string, number> = new Map();
  static reconcile(settings: NotificationAccountState[]): void {
    const accountId = AppStorage.get<string>('mailBannerAccountId') || '';
    if (accountId && !settings.some(value => value.accountId === accountId && value.enabled)) {
      MailBannerNotice.dismiss();
    }
  }
  static showInboxArrival(accountId: string, version: number): void {
    MailBannerNotice.show(accountId, version, 'inbox');
  }
  static show(accountId: string, version: number, source: string = 'notification'): void {
    const key = `${source}:${accountId}`;
    if (!accountId || version <= (MailBannerNotice.delivered.get(key) || 0)) { return; }
    MailBannerNotice.delivered.set(key, version);
    if (!MailInboxUpdates.isForeground()) { return; }
    // The cache refresh and OS alert can report the same arrival. Group them
    // while this account's banner is already visible.
    if (AppStorage.get<string>('mailBannerAccountId') === accountId &&
      Date.now() - (AppStorage.get<number>('mailBannerAt') || 0) < 7000) { return; }
    AppStorage.setOrCreate('mailBannerAccountId', accountId);
    AppStorage.setOrCreate('mailBannerAt', Date.now());
    AppStorage.setOrCreate('mailBannerRevision', (AppStorage.get<number>('mailBannerRevision') || 0) + 1);
  }
  static dismiss(): void {
    AppStorage.setOrCreate('mailBannerAccountId', '');
    AppStorage.setOrCreate('mailBannerAt', 0);
    AppStorage.setOrCreate('mailBannerRevision', (AppStorage.get<number>('mailBannerRevision') || 0) + 1);
  }
  static open(): void {
    const accountId = AppStorage.get<string>('mailBannerAccountId') || '';
    MailBannerNotice.dismiss();
    if (!accountId) { return; }
    AppStorage.setOrCreate('mailNotificationAccountId', accountId);
    AppStorage.setOrCreate('mailNotificationOpenRevision', (AppStorage.get<number>('mailNotificationOpenRevision') || 0) + 1);
  }
}
