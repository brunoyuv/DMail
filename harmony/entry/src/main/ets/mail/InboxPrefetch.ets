// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { MailCache } from '../data/MailCache';
import { cacheIsFresh } from '../data/MailCacheModel';
import { JmapService, JmapEmail, JmapError } from './jmap/JmapClient';
import { MailMessageLoader, MailMessageLoadCancelled } from './MailMessageLoader';
import { AutomaticMailWork, AutomaticMailWorkCancelled } from './AutomaticMailWork';
import { MailSyncPower } from './MailSyncPower';
import { mailSyncThermallyAllowed } from './MailSyncPacing';

interface InboxPrefetchContext {
  client: JmapService; account: SavedAccount; mailboxId: string;
  pending: Map<string, JmapEmail>; attempted: Set<string>;
  sourceEmails?: JmapEmail[];
  position: number | null; queryState?: string; sourceState?: string;
  revision: number; show: string; hide: string;
  failures: number; resumeAt: number; authenticationBlocked: boolean;
}

// Foreground-only preparation for the active Inbox. The durable mail/document
// cache is shared with the reader; this queue and cursor live only in this view's
// app session. It never changes the visible list or marks a message as read.
export class InboxPrefetch {
  private context: InboxPrefetchContext | null = null;
  private loader: MailMessageLoader;
  private task: Promise<void> | null = null;
  private timer: number = -1;
  private closed: boolean = false;
  private stopPower: () => void;
  private store: AccountStore;
  private canRun: () => boolean;
  constructor(store: AccountStore, canRun: () => boolean) {
    this.store = store; this.canRun = canRun;
    this.loader = new MailMessageLoader(store);
    this.stopPower = MailSyncPower.subscribe(() => this.wake());
  }

  update(client: JmapService, account: SavedAccount, mailboxId: string, emails: JmapEmail[],
    nextPosition: number | null, queryState: string | undefined, show: string, hide: string): void {
    if (this.closed) { return; }
    let context = this.context;
    if (!context || context.client !== client || context.account.id !== account.id ||
      context.account.serverId !== account.serverId || context.mailboxId !== mailboxId) {
      this.clear();
      context = { client, account, mailboxId, pending: new Map(), attempted: new Set(), position: nextPosition,
        queryState, sourceState: queryState, revision: 0, show, hide, failures: 0, resumeAt: 0, authenticationBlocked: false };
      this.context = context;
    } else if (context.sourceState !== queryState) {
      // A new header snapshot supersedes the traversal cursor. A retired page
      // cannot overwrite it when its old request finishes.
      ++context.revision; context.sourceState = queryState; context.queryState = queryState; context.position = nextPosition; context.pending.clear(); context.sourceEmails = undefined;
    }
    context.show = show; context.hide = hide;
    // UI interaction callbacks also update permission. They must still wake or
    // pause work, but immutable, unchanged header arrays need no admission scan.
    if (context.sourceEmails !== emails) {
      context.sourceEmails = emails;
      for (const mail of emails) {
        if (!context.attempted.has(mail.id)) { context.pending.set(mail.id, mail); }
      }
    }
    this.wake();
  }

  pause(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.loader.cancel(); AutomaticMailWork.cancelInactive();
  }
  clear(): void { this.context = null; this.pause(); }
  async close(): Promise<void> {
    this.closed = true; this.clear(); this.stopPower(); await this.whenIdle();
  }
  async whenIdle(): Promise<void> {
    while (this.task) { await this.task; }
    await this.loader.whenIdle();
  }
  private available(context: InboxPrefetchContext): boolean {
    return !this.closed && this.context === context && this.canRun() &&
      mailSyncThermallyAllowed(MailSyncPower.level()) && !context.authenticationBlocked;
  }
  private hasWork(context: InboxPrefetchContext): boolean { return context.pending.size > 0 || context.position !== null; }
  private wake(): void {
    const context = this.context;
    if (!context || !this.available(context)) { this.pause(); return; }
    if (this.task || this.timer !== -1 || !this.hasWork(context)) { return; }
    const remaining = context.resumeAt - Date.now();
    if (remaining > 0) {
      this.timer = setTimeout(() => { this.timer = -1; this.wake(); }, remaining); return;
    }
    const task = this.drain(context).catch(() => { this.backoff(context); });
    this.task = task; this.store.trackMailSync(task);
    task.then(() => {
      if (this.task === task) { this.task = null; }
      this.wake();
    });
  }
  private backoff(context: InboxPrefetchContext): void {
    context.failures++;
    context.resumeAt = Date.now() + Math.min(600000, 60000 * Math.pow(2, Math.min(context.failures - 1, 4)));
  }
  private cancelled(error: Error): boolean {
    return error instanceof MailMessageLoadCancelled || error instanceof AutomaticMailWorkCancelled;
  }
  private async drain(context: InboxPrefetchContext): Promise<void> {
    while (this.available(context) && Date.now() >= context.resumeAt && this.hasWork(context)) {
      let mail: JmapEmail | undefined;
      for (const value of context.pending.values()) { mail = value; break; }
      if (mail) {
        const selected = mail;
        try {
          // Check only metadata here: completed bodies need no network work or
          // hydration merely to discover that they are already cached.
          const saved = await this.store.mail.emailSummary(context.account.id, mail.id);
          if (!this.available(context)) { return; }
          if (!(saved && cacheIsFresh(saved.bodySavedAt) && saved.mail.cachedBodyAvailable === true)) {
            await AutomaticMailWork.run(async () => {
              try {
                await this.loader.open(context.client, context.account, selected, context.show, context.hide,
                  () => this.available(context), true);
              } finally {
                // A UI deadline/cancellation does not release the underlying
                // request. Drain it before another automatic operation starts.
                await this.loader.whenIdle();
              }
            }, () => this.available(context));
          }
          context.attempted.add(mail.id); context.pending.delete(mail.id);
          context.failures = 0;
        } catch (error) {
          if (this.cancelled(error as Error)) { return; }
          // A broken message must not be retried indefinitely by every wake.
          // It stays incomplete in storage and retains explicit reader Retry.
          context.attempted.add(mail.id); context.pending.delete(mail.id);
          if ((error as JmapError).code === 'authenticationRequired') { context.authenticationBlocked = true; }
          this.backoff(context); return;
        }
      } else {
        const position = context.position!, revision = context.revision;
        try {
          await AutomaticMailWork.run(async () => {
            const mutation = MailCache.mutationRevision();
            const page = await context.client.emailPage(context.account.serverId, context.mailboxId, position, context.queryState, undefined, () => {
              if (!this.available(context) || revision !== context.revision) { throw new AutomaticMailWorkCancelled(); }
            });
            if (!this.available(context) || revision !== context.revision) { return; }
            if (page.accountId !== context.account.serverId || page.position !== position ||
              (page.nextPosition !== null && (!Number.isSafeInteger(page.nextPosition) || page.nextPosition <= position))) {
              throw new JmapError('invalidResponse');
            }
            await this.store.mail.saveSyncedEmails(context.account.id, page.emails, mutation);
            if (!this.available(context) || revision !== context.revision) { return; }
            context.position = page.nextPosition; context.queryState = page.queryState;
            for (const value of page.emails) {
              if (!context.attempted.has(value.id)) { context.pending.set(value.id, value); }
            }
            context.failures = 0;
          }, () => this.available(context) && revision === context.revision);
        } catch (error) {
          if (this.cancelled(error as Error)) { return; }
          if ((error as JmapError).code === 'authenticationRequired') { context.authenticationBlocked = true; }
          if (revision === context.revision) {
            if ((error as JmapError).code === 'queryChanged') { context.position = 0; context.queryState = undefined; }
            else if ((error as JmapError).code === 'invalidResponse') { context.position = null; }
          }
          this.backoff(context); return;
        }
      }
    }
  }
}
