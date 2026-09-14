// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore } from '../../data/AccountStore';
import { MailOperations } from '../MailOperations';
import { NotificationPlatform } from './NotificationPlatform';

// Foreground actions and WorkScheduler use the same persisted, opt-in-filtered
// totals. Notification publication never increments or replaces them with one.
export class MailBadgeService {
  private static pending: Promise<void> = Promise.resolve();

  private static async count(store: AccountStore): Promise<number | null> {
    try { return await store.badges.total(MailOperations.overlay, MailOperations.pendingEmailIds); }
    catch (_) { return null; }
  }

  static refresh(store: AccountStore): Promise<void> {
    const task = MailBadgeService.pending.catch(() => {}).then(async (): Promise<void> => {
      let count = await MailBadgeService.count(store);
      for (let attempt = 0; attempt < 3; attempt++) {
        // An unavailable total must not invent a count or retain a badge that
        // could include an account the user has just muted.
        await NotificationPlatform.setUnreadBadge(count ?? 0);
        const latest = await MailBadgeService.count(store);
        if (latest === count) { return; }
        count = latest;
      }
      await NotificationPlatform.setUnreadBadge(count ?? 0);
    });
    MailBadgeService.pending = task.catch(() => {});
    return task;
  }
}
