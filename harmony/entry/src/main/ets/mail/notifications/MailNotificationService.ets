// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { AccountStore, SavedAccount } from '../../data/AccountStore';
import { NativeImapClient, stopInboxWatch } from '../imap/NativeImapClient';
import { NativeJmapAccountCore } from '../jmap/NativeJmapAccountCore';
import { JmapCredentials, JmapError, JmapService, JmapEmailPage } from '../jmap/JmapClient';
import { AutomaticMailWork, AutomaticMailWorkCancelled } from '../AutomaticMailWork';
import { MailCache } from '../../data/MailCache';
import { NotificationAccountState, InboxCheck, InboxSummary, compareJmapInbox, scheduledMinutes, nextCheckAt } from './NotificationModel';
import { NotificationEnvironment, runNotificationChecks } from './NotificationEngine';
import { NotificationPlatform } from './NotificationPlatform';
import { MailInboxUpdates } from './MailInboxUpdates';
import { MailBannerNotice } from './MailBannerNotice';
import { MailBadgeService } from './MailBadgeService';

class CheckCredentials implements JmapCredentials {
  readonly username?: string;
  private source: JmapCredentials;
  private stopped: () => boolean;
  private permitted?: () => Promise<boolean>;
  constructor(source: JmapCredentials, stopped: () => boolean, permitted?: () => Promise<boolean>) {
    this.source = source; this.stopped = stopped; this.permitted = permitted; this.username = source.username;
  }
  async authorization(): Promise<string> {
    if (this.stopped()) { throw new Error('Mail check cancelled'); }
    const authorization = await this.source.authorization();
    // NativeImapClient resolves credentials internally before entering NAPI.
    // A delayed unlock/token refresh must not start a stopped watch or check.
    if (this.stopped() || (this.permitted && !await this.permitted())) { throw new AutomaticMailWorkCancelled(); }
    return authorization;
  }
}

class CheckEnvironment implements NotificationEnvironment {
  private context: common.Context;
  private store: AccountStore;
  private accounts: SavedAccount[];
  private background: boolean;
  private stopped: () => boolean;
  private checkDeadline: number = Date.now() + 60000;
  constructor(context: common.Context, store: AccountStore, accounts: SavedAccount[], background: boolean, stopped: () => boolean) {
    this.context = context; this.store = store; this.accounts = accounts; this.background = background; this.stopped = stopped;
  }
  now(): number { return Date.now(); }
  cancelled(): boolean { return this.stopped() || Date.now() >= this.checkDeadline; }
  permitted(): Promise<boolean> { return NotificationPlatform.isEnabled(); }
  private async mayCheck(settings: NotificationAccountState): Promise<boolean> {
    if (this.cancelled() || !await this.permitted()) { return false; }
    const current = await this.store.notifications.get(settings.accountId);
    return !this.cancelled() && current.enabled && current.revision === settings.revision;
  }
  private network<T>(settings: NotificationAccountState, operation: () => Promise<T>): Promise<T> {
    return AutomaticMailWork.run(async () => {
      // Permission/settings can change during the shared nonblocking wait.
      if (!await this.mayCheck(settings)) { throw new AutomaticMailWorkCancelled(); }
      return operation();
    }, () => !this.cancelled());
  }
  async check(value: NotificationAccountState): Promise<InboxCheck> {
    const account = this.accounts.find(account => account.id === value.accountId);
    if (!account) { throw new Error('Account unavailable'); }
    const credentials = new CheckCredentials(this.store.credentials(account, this.background), () => this.cancelled(), () => this.mayCheck(value));
    const badgeGuard = await this.store.badges.beginCheck(account.id).catch(() => null);
    if (this.stopped()) { throw new Error('Mail check cancelled'); }
    if (account.sessionUrl.startsWith('imaps://')) {
      const client = new NativeImapClient(account.sessionUrl, credentials, account.username);
      const result = await this.network(value, () => client.checkInbox(account.serverId, value.cursor || undefined));
      if (result.unreadEmails !== undefined) {
        await this.store.badges.record(account.id, badgeGuard, result.unreadEmails, result.mailboxId, this.now()).catch(() => {});
      }
      await this.syncInbox(account, value, result, client);
      return result;
    }
    // Use the original Swift JMAP facade directly, with no extra connect.
    const core = new NativeJmapAccountCore();
    let mailboxId = value.mailboxId;
    let boxes = mailboxId ? null : await this.network(value,
      async () => core.mailboxes(account.sessionUrl, await credentials.authorization(), account.serverId));
    if (this.stopped()) { throw new Error('Mail check cancelled'); }
    if (!mailboxId) {
      mailboxId = boxes?.find(box => box.role === 'inbox')?.id || '';
      if (!mailboxId || this.stopped()) { throw new Error('Inbox unavailable'); }
    }
    const cacheRevision = this.background && this.store.mailSyncAvailable ? MailCache.mutationRevision() : 0;
    const page = await this.network(value, async () => core.emailPage(account.sessionUrl, await credentials.authorization(), account.serverId, mailboxId, 0));
    if (this.stopped()) { throw new Error('Mail check cancelled'); }
    const result = compareJmapInbox(value.cursor, mailboxId, page.emails.map((mail): InboxSummary => ({
      id: mail.id, receivedAt: mail.receivedAt, unread: !mail.keywords.includes('$seen') })), page.nextPosition, page.notFound);
    // Mailbox/get supplies a full count independent of the bounded arrival
    // page. Reuse the discovery response on the first check.
    try {
      if (!boxes) { boxes = await this.network(value, async () => core.mailboxes(account.sessionUrl, await credentials.authorization(), account.serverId)); }
      if (this.stopped()) { return result; }
      const inbox = boxes.find(box => box.id === mailboxId && box.role === 'inbox');
      if (inbox && inbox.countsKnown !== false && Number.isSafeInteger(inbox.unreadEmails) &&
        inbox.unreadEmails >= 0 && inbox.unreadEmails <= inbox.totalEmails) {
        result.unreadEmails = inbox.unreadEmails;
        await this.store.badges.record(account.id, badgeGuard, inbox.unreadEmails, mailboxId, this.now());
      }
    } catch (_) { /* Preserve the previous count and successful arrival check. */ }
    if (this.background && this.store.mailSyncAvailable) {
      await this.syncInbox(account, value, result, null, page, cacheRevision);
    }
    return result;
  }

  private async syncInbox(account: SavedAccount, settings: NotificationAccountState, check: InboxCheck, client: JmapService | null,
    suppliedPage?: JmapEmailPage, suppliedRevision: number = 0): Promise<void> {
    // Background checks may refresh one header page, but never download raw
    // bodies/pictures or resume the old persisted bulk queue.
    if (!this.background || !this.store.mailSyncAvailable || this.cancelled()) { return; }
    try {
      if (!await this.mayCheck(settings)) { return; }
      const cached = await this.store.mail.view(account.id, check.mailboxId, true, false);
      if (this.cancelled()) { return; }
      let page = suppliedPage, revision = suppliedRevision;
      if (!page && client && (check.state !== settings.cursor || !cached)) {
        revision = MailCache.mutationRevision();
        const known = (cached?.emails || []).filter(mail => mail.preview.trim().length > 0).slice(0, 500).map(mail => mail.id);
        page = await this.network(settings, () => client.emailPage(account.serverId, check.mailboxId, 0, undefined, known));
      }
      if (this.cancelled() || !await this.mayCheck(settings)) { return; }
      if (page) {
        await this.store.mail.saveView(account.id, check.mailboxId, page.emails, page.nextPosition, page.queryState, revision);
      }
    } catch (_) { /* Header caching cannot discard a successful bounded arrival check. */ }
  }
  async publish(value: NotificationAccountState): Promise<void> {
    await NotificationPlatform.publish(this.context, value.notificationId, value.accountId);
  }
  published(value: NotificationAccountState): void {
    MailBannerNotice.show(value.accountId, value.noticeVersion);
  }
  cancel(notificationId: number): Promise<void> { return NotificationPlatform.cancel(notificationId); }
}
interface ForegroundWatch { id: string; accountId: string; revision: number; alerts: boolean; }

export class MailNotificationService {
  private static foreground: boolean = false;
  private static generation: number = 0;
  private static timer: number = -1;
  private static watches: Map<string, ForegroundWatch> = new Map();
  private static idleAccounts: Set<string> = new Set();
  private static fallbackAccounts: Set<string> = new Set();
  private static retryAfter: Map<string, number> = new Map();
  private static context?: common.Context;
  private static reconciling: boolean = false;
  private static configurationRevision: number = 0;
  private static visibleAccountId: string = '';
  private static visibleRefreshAt: Map<string, number> = new Map();
  private static reconcileAgain: boolean = false;

  static setVisibleAccount(accountId: string): void {
    if (MailNotificationService.visibleAccountId === accountId) { return; }
    MailNotificationService.visibleAccountId = accountId;
    MailNotificationService.requestTick();
  }
  static credentialsChanged(accountId: string): void {
    if (!accountId) { return; }
    // Explicit reconnect replaces stored credentials while an authenticated
    // IDLE session still owns its original login. Invalidate only that account.
    ++MailNotificationService.configurationRevision;
    const watch = MailNotificationService.watches.get(accountId);
    MailNotificationService.watches.delete(accountId); MailNotificationService.idleAccounts.delete(accountId);
    MailNotificationService.fallbackAccounts.delete(accountId); MailNotificationService.retryAfter.delete(accountId);
    if (watch) { stopInboxWatch(watch.id).catch(() => {}); }
    MailNotificationService.requestTick();
  }
  private static requestTick(): void {
    if (!MailNotificationService.foreground || !MailNotificationService.context) { return; }
    if (MailNotificationService.reconciling) { MailNotificationService.reconcileAgain = true; return; }
    MailNotificationService.tick(MailNotificationService.context).catch(() => {});
  }

  static onForeground(context: common.Context): void {
    MailNotificationService.context = context;
    if (MailNotificationService.foreground) { return; }
    MailNotificationService.foreground = true; ++MailNotificationService.generation;
    MailInboxUpdates.setForeground(true);
    MailNotificationService.settingsChanged(context).catch(() => {});
    MailNotificationService.timer = setInterval(() => MailNotificationService.requestTick(), 60000);
  }
  static onBackground(): void {
    MailNotificationService.foreground = false; ++MailNotificationService.generation;
    MailInboxUpdates.setForeground(false);
    AutomaticMailWork.cancelInactive();
    if (MailNotificationService.timer !== -1) { clearInterval(MailNotificationService.timer); MailNotificationService.timer = -1; }
    for (const watch of MailNotificationService.watches.values()) { stopInboxWatch(watch.id).catch(() => {}); }
    MailNotificationService.watches.clear(); MailNotificationService.idleAccounts.clear(); MailNotificationService.fallbackAccounts.clear(); MailNotificationService.retryAfter.clear();
    MailNotificationService.visibleRefreshAt.clear(); MailNotificationService.reconcileAgain = false;
  }
  static async settingsChanged(context: common.Context): Promise<void> {
    const revision = ++MailNotificationService.configurationRevision;
    MailNotificationService.fallbackAccounts.clear(); MailNotificationService.retryAfter.clear();
    const store = new AccountStore();
    try {
      await store.openForMailChecks(context);
      const settings = await store.notifications.list();
      if (revision !== MailNotificationService.configurationRevision) { return; }
      MailBannerNotice.reconcile(settings);
      await MailBadgeService.refresh(store).catch(() => {});
      const permitted = await NotificationPlatform.isEnabled();
      if (revision !== MailNotificationService.configurationRevision) { return; }
      await NotificationPlatform.schedule(context, permitted ? scheduledMinutes(settings) : null);
    } catch (_) { throw new Error('Background checking could not be scheduled'); }
    finally {
      await store.close();
      // A background registration failure must not delay live inbox updates.
      MailNotificationService.requestTick();
    }
  }
  private static async tick(context: common.Context): Promise<void> {
    if (!MailNotificationService.foreground || MailNotificationService.reconciling) { return; }
    MailNotificationService.reconciling = true;
    const generation = MailNotificationService.generation, configuration = MailNotificationService.configurationRevision;
    const store = new AccountStore();
    try {
      await store.openForMailChecks(context);
      const settings = await store.notifications.list(), accounts = await store.list();
      const permitted = await NotificationPlatform.isEnabled().catch(() => false);
      // A settings change can finish while permission lookup is pending. Do
      // not start or stop native watches using the superseded account snapshot.
      if (!MailNotificationService.foreground || generation !== MailNotificationService.generation ||
        configuration !== MailNotificationService.configurationRevision) { return; }
      for (const accountId of MailNotificationService.retryAfter.keys()) {
        if ((MailNotificationService.retryAfter.get(accountId) || 0) <= Date.now()) {
          MailNotificationService.retryAfter.delete(accountId); MailNotificationService.fallbackAccounts.delete(accountId);
        }
      }
      for (const watch of MailNotificationService.watches.values()) {
        const selected = settings.find(value => value.accountId === watch.accountId);
        const wanted = accounts.some(account => account.id === watch.accountId) &&
          (watch.accountId === MailNotificationService.visibleAccountId || (permitted && selected?.enabled === true));
        if (!wanted || (selected?.revision || 0) !== watch.revision || (permitted && selected?.enabled === true) !== watch.alerts) {
          await stopInboxWatch(watch.id).catch(() => {});
          MailNotificationService.watches.delete(watch.accountId); MailNotificationService.idleAccounts.delete(watch.accountId);
          MailNotificationService.fallbackAccounts.delete(watch.accountId);
        }
      }
      if (!MailNotificationService.foreground || generation !== MailNotificationService.generation ||
        configuration !== MailNotificationService.configurationRevision) { return; }
      for (const account of accounts) {
        const value = settings.find(setting => setting.accountId === account.id);
        const visible = account.id === MailNotificationService.visibleAccountId;
        if ((visible || (permitted && value?.enabled === true)) && account.sessionUrl.startsWith('imaps://') &&
          !MailNotificationService.watches.has(account.id) && !MailNotificationService.fallbackAccounts.has(account.id)) {
          const watch: ForegroundWatch = { id: util.generateRandomUUID(), accountId: account.id,
            revision: value?.revision || 0, alerts: permitted && value?.enabled === true };
          MailNotificationService.watches.set(account.id, watch);
          MailNotificationService.watch(context, account, watch, generation);
        }
        // Notification permission controls OS alerts, not updates in the app
        // the user is currently using. Non-IDLE servers use the same chosen
        // foreground fallback frequency without adding another protocol client.
        if (visible && (!account.sessionUrl.startsWith('imaps://') || MailNotificationService.fallbackAccounts.has(account.id))) {
          const last = MailNotificationService.visibleRefreshAt.get(account.id) || 0;
          if (last === 0 || Date.now() - last >= (value?.foregroundMinutes || 5) * 60000) {
            MailNotificationService.visibleRefreshAt.set(account.id, Date.now());
            MailInboxUpdates.request(account.id);
          }
        }
      }
    } catch (_) { /* Retry safely on a later foreground tick. */ }
    finally {
      await store.close(); MailNotificationService.reconciling = false;
      if (MailNotificationService.reconcileAgain) {
        MailNotificationService.reconcileAgain = false;
        setTimeout(() => MailNotificationService.requestTick(), 0);
      }
    }
    await MailNotificationService.run(context, false, () => !MailNotificationService.foreground || generation !== MailNotificationService.generation);
  }
  private static async watch(context: common.Context, account: SavedAccount, watch: ForegroundWatch, generation: number): Promise<void> {
    const store = new AccountStore();
    const cancelled = (): boolean => !MailNotificationService.foreground || generation !== MailNotificationService.generation ||
      MailNotificationService.watches.get(account.id)?.id !== watch.id;
    try {
      await store.openForMailChecks(context);
      const client = new NativeImapClient(account.sessionUrl, new CheckCredentials(store.credentials(account), cancelled), account.username);
      let pending = false, started = false;
      let retryCheckAt = 0;
      while (!cancelled()) {
        // Pace only establishment. Later watch calls read a local native event
        // flag; the existing persistent IMAP IDLE connection stays available.
        const event = started ? await client.watchInbox(watch.id) :
          await AutomaticMailWork.run(() => client.watchInbox(watch.id), () => !cancelled());
        started = true;
        if (cancelled()) { break; }
        if (!event.supported) { MailNotificationService.fallbackAccounts.add(account.id); break; }
        MailNotificationService.idleAccounts.add(account.id);
        if (event.changed) {
          // Readiness refreshes a cached inbox on resume; later EXISTS events
          // refresh it even when the arriving message is already marked read.
          MailNotificationService.visibleRefreshAt.set(account.id, Date.now());
          MailInboxUpdates.request(account.id);
        }
        pending = watch.alerts && (pending || event.changed);
        if (pending && Date.now() >= retryCheckAt) {
          if (await MailNotificationService.run(context, false, cancelled, account.id)) { pending = false; }
          else {
            retryCheckAt = Date.now() + 10000;
            // Retain the event, but avoid reopening stores and rewriting the
            // badge every ten seconds during a persisted network-error backoff.
            const latest = await store.notifications.get(account.id).catch(() => null);
            if (latest?.enabled && latest.failures > 0) {
              retryCheckAt = Math.max(retryCheckAt, nextCheckAt(latest, false, Date.now()));
            }
          }
        }
        // This samples an in-process native event flag, not the mail server.
        // The Swift IDLE session remains connected between these quick calls.
        if (!cancelled()) { await new Promise<void>(resolve => setTimeout(resolve, 1000)); }
      }
    } catch (error) {
      // A broken/unsupported watch uses the configured polling interval for
      // this foreground session; reopening starts a fresh IDLE negotiation.
      if (!cancelled()) {
        MailNotificationService.fallbackAccounts.add(account.id);
        const restarting = (error as JmapError).code === 'watchRestart';
        MailNotificationService.retryAfter.set(account.id, Date.now() + (restarting ? 0 : 5 * 60000));
        if (restarting) { setTimeout(() => MailNotificationService.requestTick(), 500); }
      }
    } finally {
      const activeWatch = !cancelled();
      await stopInboxWatch(watch.id).catch(() => {}); await store.close();
      if (MailNotificationService.watches.get(account.id)?.id === watch.id) { MailNotificationService.watches.delete(account.id); MailNotificationService.idleAccounts.delete(account.id); }
      if (activeWatch && MailNotificationService.fallbackAccounts.has(account.id)) { MailNotificationService.requestTick(); }
    }
  }
  static async run(context: common.Context, background: boolean, cancelled: () => boolean = (): boolean => false,
    forcedAccount: string = ''): Promise<boolean> {
    const store = new AccountStore();
    try {
      await store.openForMailChecks(context);
      const environment = new CheckEnvironment(context, store, await store.list(), background, cancelled);
      return await runNotificationChecks(store.notifications, environment, util.generateRandomUUID(), background, forcedAccount,
        background ? [] : Array.from(MailNotificationService.idleAccounts));
    } catch (_) { return false; /* Never expose credentials/provider payloads. */ }
    finally {
      // Silent baselines and read changes update the badge too. Always use
      // current opt-in state; publication must never replace the total by one.
      await MailBadgeService.refresh(store).catch(() => {});
      await store.close();
    }
  }
}
