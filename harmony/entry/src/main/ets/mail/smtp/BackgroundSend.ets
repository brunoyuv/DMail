// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore, SavedAccount } from '../../data/AccountStore';
import { OutgoingDraft, SmtpSettings, SmtpError, SmtpSubmission, SentCopyDestination, submitMail } from './NativeSmtpClient';
import { sentMailbox, sentMessage, sendFailureState, sendFailureLabel, sentCompletionLabel, setSendFailure, sendFailureDiagnostic } from './SentMail';

interface SendingJob { account: SavedAccount; store: AccountStore; draft: OutgoingDraft; settings: SmtpSettings; }
export interface SendNotice { accountId: string; label: string; diagnostic?: string; }

// A foreground process job survives navigation and account switches. Durable
// 'sending' is written before the first network call; process interruption is
// never interpreted as permission to replay SMTP automatically.
export class BackgroundSend {
  private static active: Set<string> = new Set();
  private static accepted: Set<string> = new Set();
  private static idleWaiters: Array<() => void> = [];
  private static notices: SendNotice[] = [];

  static isSending(accountId: string): boolean { return BackgroundSend.active.has(accountId); }
  static wasAccepted(accountId: string, draftId: string): boolean { return BackgroundSend.accepted.has(`${accountId}:${draftId}`); }
  static whenIdle(): Promise<void> {
    if (BackgroundSend.active.size === 0) { return Promise.resolve(); }
    return new Promise<void>(resolve => { BackgroundSend.idleWaiters.push(resolve); });
  }
  private static finished(accountId: string): void {
    BackgroundSend.active.delete(accountId);
    if (BackgroundSend.active.size === 0) {
      const waiters = BackgroundSend.idleWaiters; BackgroundSend.idleWaiters = [];
      for (const done of waiters) { done(); }
    }
  }
  static publish(accountId: string, notice: string, failureStage: string = '', failureCode: string = ''): void {
    const diagnostic = sendFailureDiagnostic({ failureStage, failureCode });
    if (notice !== '') {
      const value: SendNotice = { accountId, label: notice };
      if (diagnostic) { value.diagnostic = diagnostic; }
      BackgroundSend.notices.push(value);
    }
    AppStorage.setOrCreate('mailSendAccountId', accountId);
    AppStorage.setOrCreate('mailSendNotice', notice);
    AppStorage.setOrCreate('mailSendRevision', (AppStorage.get<number>('mailSendRevision') || 0) + 1);
  }
  static takeNotices(): SendNotice[] {
    const notices = BackgroundSend.notices; BackgroundSend.notices = []; return notices;
  }

  // Resolves once local validation and persistence finish. SMTP/OAuth/IMAP run
  // separately, allowing the caller to return to the inbox immediately.
  static async queue(account: SavedAccount, store: AccountStore, draft: OutgoingDraft, settings: SmtpSettings): Promise<void> {
    if (BackgroundSend.isSending(account.id)) { throw new SmtpError('alreadySending'); }
    if (BackgroundSend.wasAccepted(account.id, draft.id)) { throw new SmtpError('alreadySent'); }
    draft.failureStage = ''; draft.failureCode = '';
    BackgroundSend.active.add(account.id);
    const job: SendingJob = { account: JSON.parse(JSON.stringify(account)) as SavedAccount, store,
      draft: JSON.parse(JSON.stringify(draft)) as OutgoingDraft, settings: JSON.parse(JSON.stringify(settings)) as SmtpSettings };
    try {
      await submitMail(job.settings, job.account.emailAddress, job.draft, true,
        job.account.authentication === 'oauth' ? '' : undefined);
      await store.saveSmtp(job.account, job.settings);
      job.draft.state = 'sending';
      await store.saveOutgoing(job.account.id, job.draft);
      BackgroundSend.perform(job);
    } catch (error) {
      job.settings.password = ''; BackgroundSend.finished(job.account.id); throw (error as Error);
    }
  }

  private static async saveSent(job: SendingJob, result: SmtpSubmission): Promise<void> {
    const cached = await job.store.mail.boxes(job.account.id);
    const boxes = cached?.boxes || [];
    const box = sentMailbox(boxes, result);
    const mail = sentMessage(job.account.emailAddress, job.draft, result, box.id);
    await job.store.mail.appendSent(job.account.id, mail, box);
  }

  private static async perform(job: SendingJob): Promise<void> {
    let attempted = false, accepted = false, acceptedAt = 0, notice = '';
    let stage = job.account.authentication === 'oauth' ? 'authRefresh' : 'smtp';
    try {
      const accessToken = job.account.authentication === 'oauth' ? await job.store.oauthAccessToken(job.account, job.settings) : undefined;
      let destination: SentCopyDestination | undefined;
      try {
        const credentials = job.store.credentials(job.account);
        destination = { sessionUrl: job.account.sessionUrl, authorization: await credentials.authorization(),
          username: credentials.username || job.account.username };
      } catch (_) { /* SMTP can still succeed; Sent-copy status is reported separately. */ }
      stage = 'smtp'; attempted = true;
      const result = await submitMail(job.settings, job.account.emailAddress, job.draft, false, accessToken, destination);
      accepted = true; BackgroundSend.accepted.add(`${job.account.id}:${job.draft.id}`);
      acceptedAt = result.date;
      job.draft.state = 'sent';
      await job.store.saveOutgoing(job.account.id, job.draft);
      await BackgroundSend.saveSent(job, result);
      notice = sentCompletionLabel(result.sentCopy);
    } catch (error) {
      const code = (error as SmtpError)?.code;
      if (accepted) { notice = 'sent_save_error'; }
      else {
        job.draft.state = sendFailureState(attempted, code);
        setSendFailure(job.draft, stage, code);
        notice = sendFailureLabel(job.draft.state, code);
        try { await job.store.saveOutgoing(job.account.id, job.draft); }
        catch (_) { notice = job.draft.state === 'unconfirmed' ? 'delivery_uncertain' : 'draft_save_error'; }
      }
    } finally {
      // Delivery confirmation is the only learning trigger. Save the accepted
      // message first; optional address history cannot change delivery status.
      if (accepted) { await job.store.rememberRecipients(job.account.id, job.draft, acceptedAt).catch(() => {}); }
      job.settings.password = ''; BackgroundSend.finished(job.account.id);
      BackgroundSend.publish(job.account.id, notice, job.draft.failureStage, job.draft.failureCode);
    }
  }
}
