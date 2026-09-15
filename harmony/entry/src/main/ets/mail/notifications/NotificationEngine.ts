// MPL-2.0: https://mozilla.org/MPL/2.0/
import { NotificationAccountState, InboxCheck, checkIsDue } from './NotificationModel';
import { AutomaticMailWorkCancelled } from '../AutomaticMailWork';

export interface NotificationRepository {
  list(): Promise<NotificationAccountState[]>;
  get(accountId: string): Promise<NotificationAccountState>;
  acquire(owner: string, now: number): Promise<boolean>;
  release(owner: string): Promise<void>;
  complete(accountId: string, revision: number, check: InboxCheck | null, now: number): Promise<boolean>;
  acknowledge(accountId: string, version: number): Promise<void>;
}
export interface NotificationEnvironment {
  now(): number;
  cancelled(): boolean;
  permitted(): Promise<boolean>;
  check(value: NotificationAccountState): Promise<InboxCheck>;
  publish(value: NotificationAccountState): Promise<void>;
  published?(value: NotificationAccountState): void;
  cancel(notificationId: number): Promise<void>;
}

export async function deliverPending(repository: NotificationRepository, environment: NotificationEnvironment,
  accountId: string): Promise<void> {
  if (environment.cancelled() || !await environment.permitted()) { return; }
  const current = await repository.get(accountId);
  if (environment.cancelled() || !current.enabled || current.noticeVersion <= current.acknowledgedVersion) { return; }
  await environment.publish(current);
  // A disable/remove during platform publication must remove the resulting
  // notification too. No account data is embedded in its visible text.
  const after = await repository.get(accountId);
  if (!after.enabled || after.revision !== current.revision || after.noticeVersion !== current.noticeVersion ||
    after.acknowledgedVersion >= current.noticeVersion) { await environment.cancel(current.notificationId); return; }
  await repository.acknowledge(accountId, current.noticeVersion);
  // Acknowledgement also yields to settings writes. Do not restore a muted
  // account's banner or badge after it is disabled or removed in that gap.
  const acknowledged = await repository.get(accountId);
  if (!acknowledged.enabled || acknowledged.revision !== current.revision ||
    acknowledged.noticeVersion !== current.noticeVersion) { await environment.cancel(current.notificationId); return; }
  environment.published?.(current);
}

// Background and foreground paths share a durable lease, checkpoints and
// outbox. No IMAP bodies or ordinary cache views are read or rewritten here.
export async function runNotificationChecks(repository: NotificationRepository, environment: NotificationEnvironment,
  owner: string, background: boolean, forcedAccount: string = '', idleAccounts: string[] = []): Promise<boolean> {
  if (environment.cancelled() || !await environment.permitted()) { return false; }
  if (environment.cancelled()) { return false; }
  if (!await repository.acquire(owner, environment.now())) { return false; }
  const deadline = environment.now() + 60000;
  let forcedCompleted = false;
  try {
    const accounts = await repository.list();
    for (const value of accounts) {
      if (environment.cancelled() || environment.now() >= deadline) { break; }
      if (!value.enabled || (forcedAccount && forcedAccount !== value.accountId)) { continue; }
      try { await deliverPending(repository, environment, value.accountId); } catch (_) { /* Durable outbox retries later. */ }
      if (!forcedAccount && ((!background && idleAccounts.includes(value.accountId)) || !checkIsDue(value, background, environment.now()))) { continue; }
      // Server events may bypass the configured polling interval, but repeated
      // events cannot override error backoff after an authentication/network fault.
      if (forcedAccount && value.failures > 0 && !checkIsDue(value, false, environment.now())) { continue; }
      if (environment.cancelled() || !await environment.permitted()) { break; }
      const latest = await repository.get(value.accountId);
      if (environment.cancelled()) { break; }
      if (!latest.enabled || latest.revision !== value.revision) { continue; }
      let check: InboxCheck;
      try { check = await environment.check(value); }
      catch (error) {
        if (!environment.cancelled() && !(error instanceof AutomaticMailWorkCancelled)) {
          await repository.complete(value.accountId, value.revision, null, environment.now());
        }
        continue;
      }
      if (environment.cancelled()) { break; }
      if (!await repository.complete(value.accountId, value.revision, check, environment.now())) { continue; }
      if (forcedAccount === value.accountId) { forcedCompleted = true; }
      try { await deliverPending(repository, environment, value.accountId); } catch (_) { /* Keep pending notification. */ }
    }
  } finally { await repository.release(owner); }
  return forcedAccount === '' || forcedCompleted;
}
