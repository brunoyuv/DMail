// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { MailCache } from '../data/MailCache';
import { CachedEmail, cacheIsFresh, failedEmptyMailBody } from '../data/MailCacheModel';
import { PreparedMailDocument, PreparedDocumentState, PreparedDocumentPicture } from '../data/PreparedDocumentModel';
import { JmapService, JmapEmail, JmapError } from './jmap/JmapClient';
import { stableMessageKey } from './Conversation';
import { plainTextMailHtml, preparedMailDocument } from './html/HtmlDocument';
import { prepareStaticMailHtml } from './html/HtmlPicturePlan';

export interface MailMessageResult { mail: JmapEmail; document: PreparedMailDocument | null; }
export class MailMessageLoadCancelled extends Error {
  constructor() { super('Message load cancelled'); this.name = 'MailMessageLoadCancelled'; }
}
interface MessageRequest {
  accountId: string; serverId: string; emailId: string; client: JmapService;
  active: () => boolean; cancelled: boolean; reject?: (error: Error) => void;
  task?: Promise<MailMessageResult>;
}

// Explicit selection owns the body and prepared HTML. The mounted reader owns
// progressive pictures; no picture request can delay this promise. Cached bodies
// bypass queued network reads, and every visible loading attempt has a deadline.
export class MailMessageLoader {
  private static bodyTail: Promise<void> = Promise.resolve();
  private static prepareTail: Promise<void> = Promise.resolve();
  private static documentSerial: number = 0;
  private store: AccountStore;
  private current: MessageRequest | null = null;
  private pending: Set<Promise<void>> = new Set();

  constructor(store: AccountStore) { this.store = store; }

  open(client: JmapService, account: SavedAccount, header: JmapEmail, show: string, hide: string,
    active: () => boolean): Promise<MailMessageResult> {
    const previous = this.current;
    if (previous && this.owns(previous) && previous.client === client && previous.accountId === account.id &&
      previous.serverId === account.serverId && previous.emailId === header.id && previous.task) { return previous.task; }
    this.cancel();
    const request: MessageRequest = { accountId: account.id, serverId: account.serverId, emailId: header.id,
      client, active, cancelled: false };
    this.current = request;
    const interrupted = new Promise<MailMessageResult>((_resolve, reject) => { request.reject = reject; });
    // The native timeout does not cover credentials, queued work or file/RDB
    // operations. Bound the UI wait too, without abandoning ownership of an
    // operation still finishing in storage or starting overlapping retries.
    const timer = setTimeout(() => {
      request.cancelled = true;
      request.reject?.(new JmapError('network') as Error);
    }, 45000);
    const work = this.load(request, show, hide);
    const task = Promise.race([work, interrupted]); request.task = task;
    const settled = work.then(() => {}, () => {});
    this.pending.add(settled); this.store.trackMailSync(settled);
    settled.then(() => { this.pending.delete(settled); });
    const finish = (): void => {
      clearTimeout(timer); request.reject = undefined;
      if (this.current === request) { this.current = null; }
    };
    task.then(finish, finish);
    return task;
  }

  cancel(): void {
    const request = this.current; this.current = null;
    if (!request) { return; }
    request.cancelled = true;
    request.reject?.(new MailMessageLoadCancelled() as Error);
  }

  async whenIdle(): Promise<void> {
    while (this.pending.size > 0) { await Promise.all(Array.from(this.pending)); }
  }

  private owns(request: MessageRequest): boolean {
    return this.current === request && !request.cancelled && request.active();
  }

  private requireActive(request: MessageRequest): void {
    if (!this.owns(request)) { throw new MailMessageLoadCancelled(); }
  }

  private usable(cached: CachedEmail | null, id: string): boolean {
    return cached !== null && cached.mail.id === id && cacheIsFresh(cached.bodySavedAt) && !failedEmptyMailBody(cached.mail);
  }

  private async cached(request: MessageRequest): Promise<CachedEmail | null> {
    try { return await this.store.mail.email(request.accountId, request.emailId, true); }
    catch (_) { throw new JmapError('storage'); }
  }

  private async body(request: MessageRequest): Promise<CachedEmail> {
    const work = MailMessageLoader.bodyTail.then(async (): Promise<CachedEmail> => {
      this.requireActive(request);
      // A predecessor may have saved this same body after it was deselected.
      const cached = await this.cached(request); this.requireActive(request);
      if (this.usable(cached, request.emailId)) { return cached!; }
      const revision = MailCache.mutationRevision();
      let mail: JmapEmail | null;
      try { mail = await request.client.readEmail(request.serverId, request.emailId); }
      catch (error) {
        const code = (error as JmapError)?.code;
        throw new JmapError(code === 'authenticationRequired' ? code : code === 'invalidResponse' ? code : 'network');
      }
      if (!mail) { throw new JmapError('notFound'); }
      if (mail.id !== request.emailId || failedEmptyMailBody(mail)) { throw new JmapError('invalidResponse'); }
      // The request already completed: persist it to its captured account even
      // if navigation changed. No retired request may then prepare or publish.
      try { await this.store.mail.saveEmail(request.accountId, mail, revision); }
      catch (_) { throw new JmapError('storage'); }
      this.requireActive(request);
      const saved = await this.cached(request); this.requireActive(request);
      if (!this.usable(saved, request.emailId)) { throw new JmapError('storage'); }
      return saved!;
    });
    MailMessageLoader.bodyTail = work.then(() => {}, () => {}); return work;
  }

  private async document(request: MessageRequest, cached: CachedEmail, show: string, hide: string): Promise<PreparedDocumentState> {
    const key = stableMessageKey(cached.mail);
    const unavailable: PreparedDocumentState = { document: null, attempted: false, bodySavedAt: cached.bodySavedAt, failure: '' };
    try {
      const saved = await this.store.documents.read(request.accountId, key); this.requireActive(request);
      if (saved.document || saved.failure === 'failed') { return saved; }
    } catch (error) {
      if (error instanceof MailMessageLoadCancelled) { throw error; }
      // Optional prepared HTML must not hide a successfully saved raw body.
      // A failed storage lookup is never permission to scan or fetch pictures.
      return unavailable;
    }
    const work = MailMessageLoader.prepareTail.then(async (): Promise<PreparedDocumentState> => {
      this.requireActive(request);
      try {
        const saved = await this.store.documents.read(request.accountId, key); this.requireActive(request);
        if (saved.document || saved.failure === 'failed') { return saved; }
        const prefix = `https://mail.invalid/picture/${Date.now()}_${++MailMessageLoader.documentSerial}/`;
        let html: string; let pictures: PreparedDocumentPicture[];
        try {
          const plan = prepareStaticMailHtml(cached.mail.htmlBody || plainTextMailHtml(cached.mail.textBody || ''), show, hide, prefix);
          html = preparedMailDocument(plan.html, false, 0).replace('img-src data:;', 'img-src data: https://mail.invalid;');
          pictures = plan.pictures;
        } catch (_) {
          // Preserve usable raw text and make preparation failure terminal for
          // this body, just as an already-completed picture failure is terminal.
          const failed = await this.store.documents.fail(request.accountId, key, cached.bodySavedAt!);
          this.requireActive(request); return failed;
        }
        this.requireActive(request);
        const committed = await this.store.documents.save(request.accountId, key, html, pictures, cached.bodySavedAt!);
        this.requireActive(request);
        return committed;
      } catch (error) {
        if (error instanceof MailMessageLoadCancelled) { throw error; }
        return unavailable;
      }
    });
    MailMessageLoader.prepareTail = work.then(() => {}, () => {}); return work;
  }

  private async load(request: MessageRequest, show: string, hide: string): Promise<MailMessageResult> {
    this.requireActive(request);
    let cached = await this.cached(request); this.requireActive(request);
    if (!this.usable(cached, request.emailId)) { cached = await this.body(request); }
    const body = cached!;
    const saved = await this.document(request, body, show, hide); this.requireActive(request);
    this.requireActive(request);
    return { mail: body.mail, document: saved.document };
  }
}
