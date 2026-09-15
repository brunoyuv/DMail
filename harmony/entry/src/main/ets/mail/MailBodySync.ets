// MPL-2.0: https://mozilla.org/MPL/2.0/
import { util } from '@kit.ArkTS';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { MailCache } from '../data/MailCache';
import { CachedEmail, CachedMailList, cacheIsFresh, failedEmptyMailBody } from '../data/MailCacheModel';
import { MailSyncJob, MailSyncCursor } from '../data/MailSyncModel';
import { PictureSnapshotScope } from '../data/PictureCache';
import { loadPictureSnapshot } from '../data/PictureSnapshot';
import { JmapService, JmapEmail, JmapEmailPage, JmapError } from './jmap/JmapClient';
import { stableMessageKey } from './Conversation';
import { plainTextMailHtml, preparedMailDocument } from './html/HtmlDocument';
import { prepareStaticMailHtml, StaticMailPicturePlan } from './html/HtmlPicturePlan';
import { MailSyncPower } from './MailSyncPower';
import { mailSyncRestMs, mailSyncThermallyAllowed } from './MailSyncPacing';

interface SyncBodySession { client: JmapService; id: string; }
interface SyncAccount { client: JmapService; account: SavedAccount; show: string; hide: string; revision: number; }

// Only sync registers work. Its queue and mailbox cursors survive process exit;
// the reader never fetches, prepares, retries, or schedules these jobs.
export class MailBodySync {
  private static bodyTail: Promise<void> = Promise.resolve();
  private static prepareTail: Promise<void> = Promise.resolve();
  private static pictureTail: Promise<void> = Promise.resolve();
  private static pageTail: Promise<void> = Promise.resolve();
  private static documentSerial: number = 0;
  private store: AccountStore;
  private canRun: () => boolean;
  private scope?: PictureSnapshotScope;
  private contexts: Map<string, SyncAccount> = new Map();
  private revisions: Map<string, number> = new Map();
  private registrations: Set<Promise<void>> = new Set();
  private task: Promise<void> | null = null;
  private currentAccount: string = '';
  private currentMessage: string = '';
  private paused: boolean = false;
  private closed: boolean = false;
  private activityRevision: number = 0;
  private pauseRevision: number = 0;
  private observedActivity: number = 0;
  private nextWorkAt: number = 0;
  private restTimer: number = -1;
  private retryTimer: number = -1;
  private finishRest: (() => void) | null = null;
  private stopPower: () => void;
  private bodySessions: Map<string, SyncBodySession> = new Map();
  private closingSessions: Set<Promise<void>> = new Set();

  constructor(store: AccountStore, canRun: () => boolean, scope?: PictureSnapshotScope) {
    this.store = store; this.canRun = canRun; this.scope = scope;
    this.stopPower = MailSyncPower.subscribe(() => {
      if (!mailSyncThermallyAllowed(MailSyncPower.level())) { this.pause(); }
      else { this.wake(); }
    });
  }

  enqueue(client: JmapService, account: SavedAccount, emails: JmapEmail[], show: string, hide: string): Promise<void> {
    return this.register(client, account, show, hide, () => this.store.sync.enqueue(account.id, emails));
  }

  enqueuePage(client: JmapService, account: SavedAccount, mailboxId: string, page: JmapEmailPage,
    show: string, hide: string): Promise<void> {
    return this.register(client, account, show, hide, async () => {
      if (page.position === 0) { await this.store.sync.seedPage(account.id, mailboxId, page); }
      else { await this.store.sync.enqueue(account.id, page.emails); }
    });
  }

  enqueueCached(client: JmapService, account: SavedAccount, mailboxId: string, cached: CachedMailList,
    show: string, hide: string): Promise<void> {
    return this.register(client, account, show, hide, async () => {
      await this.store.sync.seedCached(account.id, mailboxId, cached);
    });
  }

  private register(client: JmapService, account: SavedAccount, show: string, hide: string,
    persist: () => Promise<void>): Promise<void> {
    if (this.closed || !this.store.mailSyncAvailable || !account.id) { return Promise.resolve(); }
    const previous = this.contexts.get(account.id);
    if (previous && previous.client !== client) {
      this.revisions.set(account.id, (this.revisions.get(account.id) || 0) + 1);
      this.releaseSession(account.id);
    }
    const revision = this.revisions.get(account.id) || 0;
    this.contexts.set(account.id, { client, account, show, hide, revision });
    // Resolve after durable registration, not after body/picture downloads.
    const task = persist().then(() => {
      if (this.closed || revision !== (this.revisions.get(account.id) || 0)) { return; }
      if (this.currentAccount && this.currentMessage) {
        this.store.pictures.cancelPending(this.currentAccount, this.currentMessage);
      }
      this.wake();
    });
    this.registrations.add(task); this.store.trackMailSync(task);
    task.then(() => this.registrations.delete(task), () => this.registrations.delete(task));
    return task;
  }

  wake(): void {
    if (this.closed) { return; }
    this.cancelRetry();
    ++this.activityRevision; this.paused = false;
    if (this.task || !this.available() || this.contexts.size === 0) { return; }
    const task = this.drain(); this.task = task; this.store.trackMailSync(task);
    task.then(() => {
      if (this.task === task) { this.task = null; }
      // Retain a registration/resume arriving just after the final empty query.
      // Idle queues have no polling timer; persisted failures get one deadline wake.
      if (this.available() && this.activityRevision !== this.observedActivity) { this.wake(); }
    }, () => { if (this.task === task) { this.task = null; } });
  }

  pause(): void {
    ++this.activityRevision; ++this.pauseRevision; this.paused = true;
    this.cancelRest(); this.cancelRetry();
    this.releaseSessions();
    if (this.currentAccount && this.currentMessage) { this.store.pictures.cancelPending(this.currentAccount, this.currentMessage); }
  }

  cancelAccount(accountId: string): void {
    this.releaseSession(accountId);
    this.revisions.set(accountId, (this.revisions.get(accountId) || 0) + 1);
    this.contexts.delete(accountId);
    if (this.currentAccount === accountId && this.currentMessage) { this.store.pictures.cancelPending(accountId, this.currentMessage); }
    this.wake();
  }

  async close(): Promise<void> {
    this.closed = true; this.pause(); this.stopPower(); await this.whenIdle(); this.contexts.clear();
  }

  async whenIdle(): Promise<void> {
    while (this.task || this.registrations.size > 0 || this.closingSessions.size > 0) {
      await Promise.all(Array.from(this.registrations).map(task => task.catch(() => {})));
      if (this.task) { await this.task; }
      await Promise.all(Array.from(this.closingSessions));
    }
  }

  private available(): boolean {
    return !this.closed && !this.paused && this.canRun() && this.store.mailSyncAvailable &&
      mailSyncThermallyAllowed(MailSyncPower.level()) &&
      (!this.scope || (!this.scope.revoked && this.scope.active() && Date.now() < this.scope.deadline));
  }

  private owns(context: SyncAccount): boolean {
    return context.revision === (this.revisions.get(context.account.id) || 0) && this.contexts.has(context.account.id);
  }

  private async permitted(context: SyncAccount): Promise<boolean> {
    if (!this.available() || !this.owns(context)) { return false; }
    if (this.scope?.permitted && !await this.scope.permitted().catch(() => false)) { this.scope.revoked = true; }
    return this.available() && this.owns(context);
  }

  private retryAt(attempts: number): number { return Date.now() + Math.min(3600000, 60000 * Math.pow(2, Math.min(attempts, 6))); }

  private cancelRetry(): void {
    if (this.retryTimer !== -1) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
  }

  private async scheduleRetry(): Promise<void> {
    if (!this.available() || this.contexts.size === 0) { return; }
    const activity = this.activityRevision;
    const due = await this.store.sync.nextRetryAt(Array.from(this.contexts.keys())).catch(() => null);
    if (activity !== this.activityRevision || !this.available() || due === null || this.contexts.size === 0 ||
      (this.scope && due >= this.scope.deadline)) { return; }
    this.cancelRetry();
    // One wake for actual persisted failures. Successful/empty queues have no
    // timer; failed bodies can recover without another arrival or manual pull.
    this.retryTimer = setTimeout(() => { this.retryTimer = -1; this.wake(); }, Math.max(1000, due - Date.now()));
  }

  private cancelRest(): void {
    if (this.restTimer !== -1) { clearTimeout(this.restTimer); this.restTimer = -1; }
    const finish = this.finishRest; this.finishRest = null; finish?.();
  }

  private async restBeforeWork(): Promise<boolean> {
    while (this.available() && Date.now() < this.nextWorkAt) {
      const remaining = Math.min(this.nextWorkAt - Date.now(), this.scope ? Math.max(0, this.scope.deadline - Date.now()) : 10000);
      if (remaining <= 0) { return false; }
      await new Promise<void>(resolve => {
        this.finishRest = resolve;
        this.restTimer = setTimeout(() => { this.restTimer = -1; this.finishRest = null; resolve(); }, remaining);
      });
    }
    return this.available();
  }

  private releaseSession(accountId: string): void {
    const session = this.bodySessions.get(accountId);
    if (!session) { return; }
    this.bodySessions.delete(accountId);
    // Delete ownership before async close, so a rapid resume gets a new UUID.
    const close = session.client.closeSyncSession!(session.id).catch(() => {});
    this.closingSessions.add(close); this.store.trackMailSync(close);
    close.then(() => this.closingSessions.delete(close));
  }

  private releaseSessions(): void {
    for (const accountId of Array.from(this.bodySessions.keys())) { this.releaseSession(accountId); }
  }

  private async syncedBody(context: SyncAccount, emailId: string): Promise<JmapEmail | null> {
    if (!context.client.readEmailForSync || !context.client.closeSyncSession) {
      return context.client.readEmail(context.account.serverId, emailId);
    }
    let session = this.bodySessions.get(context.account.id);
    if (!session) {
      session = { client: context.client, id: util.generateRandomUUID() };
      this.bodySessions.set(context.account.id, session);
    }
    return session.client.readEmailForSync!(context.account.serverId, emailId, session.id);
  }

  private async drain(): Promise<void> {
    let completed = false;
    try { await this.drainOwned(); completed = true; }
    finally {
      this.releaseSessions(); await Promise.all(Array.from(this.closingSessions));
      // A corrupt queue/failed database selection cannot become a one-second
      // wake loop merely because an older retry deadline is now due.
      if (completed) { await this.scheduleRetry(); }
    }
  }

  private async drainOwned(): Promise<void> {
    while (this.available() && this.contexts.size > 0) {
      const activity = this.activityRevision; this.observedActivity = activity;
      const accounts = Array.from(this.contexts.keys());
      // One bounded record at a time. Bodies/docs across discovered pages take
      // precedence over slow or broken remote picture hosts.
      let job = (await this.store.sync.next(accounts, 'body', 1))[0];
      let cursor: MailSyncCursor | null = null;
      if (!job) { cursor = await this.store.sync.nextCursor(accounts); }
      if (!job && !cursor) { job = (await this.store.sync.next(accounts, 'pictures', 1))[0]; }
      if (!job && !cursor) { break; }
      if (cursor || job?.stage === 'pictures') { this.releaseSessions(); }
      const accountId = job ? job.accountId : cursor!.accountId, context = this.contexts.get(accountId);
      if (!context || !this.available()) { continue; }
      if (!await this.restBeforeWork()) { break; }
      this.currentAccount = accountId; this.currentMessage = '';
      const started = Date.now(), pausedAtStart = this.pauseRevision;
      let finished = false;
      try {
        finished = cursor ? await this.page(context, cursor) : job.stage === 'body' ?
          await this.prepareBody(context, job) : await this.pictures(context, job);
      } catch (_) {
        // Durable backoff uses a later deadline wake; this loop cannot retry
        // its own failure or discard the remaining mailbox backlog.
        this.releaseSession(accountId);
        if (this.owns(context) && this.available() && pausedAtStart === this.pauseRevision) {
          if (cursor) { await this.store.sync.deferCursor(cursor, this.retryAt(cursor.attempts)); }
          else { await this.store.sync.defer(accountId, job.email.id, this.retryAt(job.attempts)); }
        }
        finished = true;
      } finally { this.currentAccount = ''; this.currentMessage = ''; }
      this.nextWorkAt = Date.now() + mailSyncRestMs(Date.now() - started, MailSyncPower.level());
      if (!finished) {
        if (activity === this.activityRevision) { this.paused = true; }
        break;
      }
    }
  }

  private async body(context: SyncAccount, job: MailSyncJob): Promise<CachedEmail | null | undefined> {
    const read = MailBodySync.bodyTail.then(async (): Promise<CachedEmail | null | undefined> => {
      if (!this.available() || !this.owns(context)) { return undefined; }
      const cached = await this.store.mail.email(context.account.id, job.email.id, true);
      if (cached && cacheIsFresh(cached.bodySavedAt) && !failedEmptyMailBody(cached.mail)) { return cached; }
      // Shared Message-ID HTML is not evidence that this protocol ID has its
      // own raw body, attachment metadata, or reply text saved.
      if (!await this.permitted(context)) { return undefined; }
      const revision = MailCache.mutationRevision();
      const mail = await this.syncedBody(context, job.email.id);
      if (!this.owns(context)) { return undefined; }
      if (!mail) { return null; }
      if (mail.id !== job.email.id) { throw new Error('Synced body identity changed'); }
      if (failedEmptyMailBody(mail)) { throw new Error('Synced message body could not be decoded'); }
      // Preserve an active completed body after pause; close drains this write.
      await this.store.mail.saveEmail(context.account.id, mail, revision);
      const saved = await this.store.mail.email(context.account.id, job.email.id, true);
      if (!saved) { throw new Error('Synced body was not saved'); }
      return saved;
    });
    MailBodySync.bodyTail = read.then(() => {}, () => {}); return read;
  }

  private async prepareBody(context: SyncAccount, job: MailSyncJob): Promise<boolean> {
    // Keep the absence check, HTML scan and first-document commit together;
    // simultaneous workers cannot create competing resource-ID documents.
    const work = MailBodySync.prepareTail.then(() => this.prepareBodyOwned(context, job));
    MailBodySync.prepareTail = work.then(() => {}, () => {}); return work;
  }

  private async prepareBodyOwned(context: SyncAccount, job: MailSyncJob): Promise<boolean> {
    const accountId = context.account.id, cached = await this.body(context, job);
    if (!this.owns(context)) { return true; }
    if (cached === undefined) { return false; }
    if (cached === null) { await this.store.sync.discard(accountId, job.email.id); return true; }
    if (cached.bodySavedAt === null) { throw new Error('Synced body unavailable'); }
    if (!this.available()) { return false; }
    const key = stableMessageKey(cached.mail);
    let saved = await this.store.documents.read(accountId, key);
    if (!this.available() || !this.owns(context)) { return false; }
    if (!saved.document && saved.failure !== 'failed') {
      let plan: StaticMailPicturePlan, html: string;
      try {
        const prefix = `https://mail.invalid/picture/${Date.now()}_${++MailBodySync.documentSerial}/`;
        plan = prepareStaticMailHtml(cached.mail.htmlBody || plainTextMailHtml(cached.mail.textBody || ''), context.show, context.hide, prefix);
        html = preparedMailDocument(plan.html, false, 0).replace('img-src data:;', 'img-src data: https://mail.invalid;');
      } catch (_) {
        await this.store.documents.fail(accountId, key, cached.bodySavedAt);
        await this.store.sync.markPictures(accountId, job.email.id, cached.bodySavedAt, key);
        await this.store.sync.complete(accountId, job.email.id); return true;
      }
      saved = await this.store.documents.save(accountId, key, html, plan.pictures, cached.bodySavedAt);
    }
    if (!this.owns(context)) { return true; }
    // A rejected/superseded commit can resolve without a usable document.
    // Back off instead of cycling body -> pictures -> body and rescanning.
    if (!saved.document && saved.failure !== 'failed') { throw new Error('Prepared synced document unavailable'); }
    await this.store.sync.markPictures(accountId, job.email.id, cached.bodySavedAt, key);
    if (saved.failure === 'failed' || (saved.document && saved.document.pictures.length === 0)) {
      await this.store.sync.complete(accountId, job.email.id);
    }
    return true;
  }

  private async pictures(context: SyncAccount, job: MailSyncJob): Promise<boolean> {
    const work = MailBodySync.pictureTail.then(async (): Promise<boolean> => {
      if (!this.available() || !this.owns(context)) { return false; }
      const key = job.messageKey || stableMessageKey(job.email), accountId = context.account.id;
      this.currentMessage = key;
      if (!cacheIsFresh(job.bodySavedAt)) {
        await this.store.sync.requeueBody(accountId, job.email.id); return true;
      }
      const saved = await this.store.documents.read(accountId, key);
      if (!this.available() || !this.owns(context)) { return false; }
      if (!saved.document && saved.failure !== 'failed') {
        await this.store.sync.requeueBody(accountId, job.email.id);
        throw new Error('Prepared synced document unavailable');
      }
      if (saved.failure === 'failed' || saved.document!.pictures.length === 0 || await this.store.pictures.snapshotAttempted(accountId, key)) {
        await this.store.sync.complete(accountId, job.email.id); return true;
      }
      if (!await this.permitted(context)) { return false; }
      const result = await loadPictureSnapshot(this.store.pictures, accountId, key,
        saved.document!.pictures.map(picture => picture.url), false, this.scope);
      if (!this.owns(context)) { return true; }
      if (result.cancelled) { return false; }
      if (!result.saved) { throw new Error('Picture attempt could not be saved'); }
      await this.store.sync.complete(accountId, job.email.id); return true;
    });
    MailBodySync.pictureTail = work.then(() => {}, () => {}); return work;
  }

  private async page(context: SyncAccount, cursor: MailSyncCursor): Promise<boolean> {
    const work = MailBodySync.pageTail.then(async (): Promise<boolean> => {
      if (!await this.permitted(context)) { return false; }
      const current = await this.store.sync.nextCursor([context.account.id]);
      if (!current || current.mailboxId !== cursor.mailboxId || current.revision !== cursor.revision || current.position !== cursor.position) { return true; }
      if (!await this.permitted(context)) { return false; }
      const revision = MailCache.mutationRevision();
      let page: JmapEmailPage;
      try {
        page = await context.client.emailPage(context.account.serverId, cursor.mailboxId, cursor.position || 0, cursor.queryState || undefined);
      } catch (error) {
        if ((cursor.position || 0) > 0 && ['stateMismatch', 'cannotCalculateChanges', 'queryChanged'].includes((error as JmapError | undefined)?.code || '')) {
          await this.store.sync.restartCursor(cursor, this.retryAt(cursor.attempts)); return true;
        }
        throw error as Error;
      }
      if (!this.owns(context)) { return true; }
      if ((cursor.position || 0) > 0 && page.queryState !== cursor.queryState) {
        await this.store.sync.restartCursor(cursor, this.retryAt(cursor.attempts)); return true;
      }
      if (page.position !== cursor.position || (page.nextPosition !== null && page.nextPosition <= page.position)) {
        throw new Error('Mailbox sync did not advance');
      }
      await this.store.mail.saveSyncedEmails(context.account.id, page.emails, revision);
      await this.store.sync.advance(cursor, page);
      return true;
    });
    MailBodySync.pageTail = work.then(() => {}, () => {}); return work;
  }
}
