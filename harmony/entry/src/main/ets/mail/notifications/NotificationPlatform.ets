// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common, wantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';

const MAIL_CHECK_WORK_ID = 7401;

export interface NotificationStatus {
  enabled: boolean;
  bannerEnabled?: boolean;
  badgeEnabled?: boolean;
  slotEnabled?: boolean;
}
// SDK releases before API26 expose the settings object but omit these optional
// members from its type. Runtime feature detection keeps API24 supported.
interface NotificationModeSettings extends notificationManager.NotificationSetting {
  bannerEnabled?: boolean;
  badgeNumberEnabled?: boolean;
}

// OS integration carries only an opaque account identifier. Notifications never
// include account addresses, subjects, sender names or message bodies.
export class NotificationPlatform {
  private static scheduling: Promise<void> = Promise.resolve();
  private static slotReady: boolean = false;
  private static slotTask?: Promise<void>;
  private static badgeTask: Promise<void> = Promise.resolve();
  static isEnabled(): Promise<boolean> { return notificationManager.isNotificationEnabled(); }
  static ensureSlot(): Promise<void> {
    if (NotificationPlatform.slotReady) { return Promise.resolve(); }
    if (NotificationPlatform.slotTask) { return NotificationPlatform.slotTask; }
    const task = (async (): Promise<void> => {
      const slots = await notificationManager.getSlots();
      if (!slots.some(slot => slot.notificationType === notificationManager.SlotType.SOCIAL_COMMUNICATION)) {
        await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
      }
      // Existing channels retain the user's settings, including disabled ones.
      NotificationPlatform.slotReady = true;
    })();
    const result = task.finally(() => { NotificationPlatform.slotTask = undefined; });
    NotificationPlatform.slotTask = result;
    return result;
  }
  static async settings(): Promise<NotificationStatus> {
    const enabled = await NotificationPlatform.isEnabled().catch(() => false);
    try { await NotificationPlatform.ensureSlot(); } catch (_) {}
    let slotEnabled: boolean | undefined = undefined;
    try {
      const slot = await notificationManager.getSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
      if (typeof slot?.enabled === 'boolean') { slotEnabled = slot.enabled; }
    } catch (_) {}
    try {
      const value = await notificationManager.getNotificationSetting() as NotificationModeSettings;
      // These optional fields were added in API 26. Older devices report an
      // unknown banner/badge state, which must not be presented as disabled.
      return { enabled: enabled, slotEnabled: slotEnabled,
        bannerEnabled: typeof value.bannerEnabled === 'boolean' ? value.bannerEnabled : undefined,
        badgeEnabled: typeof value.badgeNumberEnabled === 'boolean' ? value.badgeNumberEnabled : undefined };
    } catch (_) { return { enabled: enabled, slotEnabled: slotEnabled }; }
  }
  static async openSettings(context: common.UIAbilityContext): Promise<void> {
    await NotificationPlatform.ensureSlot();
    await notificationManager.openNotificationSettings(context);
  }
  static setUnreadBadge(unreadCount: number): Promise<void> {
    if (!Number.isSafeInteger(unreadCount) || unreadCount < 0) {
      return Promise.reject(new Error('Invalid unread count'));
    }
    // HarmonyOS displays values above 99 as 99+. Keep the actual count rather
    // than turning every nonempty inbox into a misleading numeric one.
    const value = Math.min(unreadCount, 2147483647);
    const task = NotificationPlatform.badgeTask.catch(() => {}).then(async (): Promise<void> => {
      await notificationManager.setBadgeNumber(value);
    });
    // The WorkScheduler process can change the OS badge while this process is
    // suspended. Never suppress a needed write using a process-local value.
    // Failed operations cannot block later updates or clears.
    NotificationPlatform.badgeTask = task.catch(() => {});
    return task;
  }
  static async requestEnable(context: common.UIAbilityContext): Promise<void> {
    await NotificationPlatform.ensureSlot();
    if (await NotificationPlatform.isEnabled()) { return; }
    await notificationManager.requestEnableNotification(context);
    if (!await NotificationPlatform.isEnabled()) { throw new Error('Notifications are not enabled'); }
  }
  static async publish(context: common.Context, notificationId: number, accountId: string): Promise<void> {
    if (!Number.isInteger(notificationId) || notificationId <= 0 || notificationId > 2147483647 || !accountId) {
      throw new Error('Invalid notification identity');
    }
    await NotificationPlatform.ensureSlot();
    const agent = await wantAgent.getWantAgent({
      wants: [{ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility',
        parameters: { mailNotificationAccountId: accountId } }],
      actionType: wantAgent.OperationType.START_ABILITY, requestCode: notificationId,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG, wantAgent.WantAgentFlags.CONSTANT_FLAG]
    });
    const request: notificationManager.NotificationRequest = {
      id: notificationId, notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      tapDismissed: true, isAlertOnce: false, badgeNumber: 0, wantAgent: agent,
      content: { notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: context.resourceManager.getStringByNameSync('new_mail_notification_title'),
          text: context.resourceManager.getStringByNameSync('new_mail_notification_text') } }
    };
    await notificationManager.publish(request);
  }
  static async cancel(id: number): Promise<void> {
    if (!Number.isInteger(id) || id <= 0) { return; }
    try { await notificationManager.cancel(id); }
    catch (error) {
      // Disabling an account before its first alert is a normal empty state.
      if ((error as BusinessError).code !== 1600007) { throw new Error('Notification could not be cleared'); }
    }
  }
  static schedule(context: common.Context, minutes: number | null): Promise<void> {
    if (minutes !== null && (!Number.isInteger(minutes) || minutes < 120 || minutes > 1440)) {
      return Promise.reject(new Error('Invalid background checking interval'));
    }
    const bundleName = context.applicationInfo.name;
    const task = NotificationPlatform.scheduling.catch(() => {}).then(async () => {
      const works = await workScheduler.obtainAllWorks();
      const previous = works.find(work => work.workId === MAIL_CHECK_WORK_ID && work.bundleName === bundleName);
      if (minutes === null) { if (previous) { workScheduler.stopWork(previous, true); } return; }
      const repeatCycleTime = minutes * 60000;
      if (previous && previous.abilityName === 'MailCheckAbility' && previous.isPersisted === true &&
        previous.networkType === workScheduler.NetworkType.NETWORK_TYPE_ANY && previous.isRepeat === true &&
        previous.repeatCycleTime === repeatCycleTime) { return; }
      const next: workScheduler.WorkInfo = { workId: MAIL_CHECK_WORK_ID, bundleName,
        abilityName: 'MailCheckAbility', isPersisted: true,
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY, isRepeat: true, repeatCycleTime };
      if (previous) { workScheduler.stopWork(previous, true); }
      try { workScheduler.startWork(next); }
      catch (_) {
        // A rejected interval change must not silently lose the existing job.
        if (previous) { try { workScheduler.startWork(previous); } catch (_) {} }
        throw new Error('Background checking could not be scheduled');
      }
    });
    NotificationPlatform.scheduling = task.catch(() => {});
    return task;
  }
}
