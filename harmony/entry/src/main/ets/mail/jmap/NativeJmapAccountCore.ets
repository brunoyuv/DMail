// MPL-2.0: https://mozilla.org/MPL/2.0/
import { jmapAccountRequest } from 'libthunderbird.so';
import { JmapAccountCore, JmapConnection, JmapSession, JmapMailbox, JmapError, JmapEmailPage, JmapEmailSnapshot, JmapKeyword, JmapArchiveUndo, JmapDraft, JmapCreatedDraft, JmapDraftError } from './JmapClient';

interface Request {
  operation: string; sessionUrl: string; authorization: string; accountId?: string;
  mailboxId?: string; position?: number; queryState?: string; emailIds?: string[]; includeBody?: boolean;
  emailId?: string; keyword?: string; enabled?: boolean; undo?: JmapArchiveUndo;
  draft?: JmapDraft;
}
interface Reply {
  session?: JmapSession; maxRequestBytes?: number; mailboxes?: JmapMailbox[]; error?: string;
  page?: JmapEmailPage; messages?: JmapEmailSnapshot;
  state?: string; undo?: JmapArchiveUndo;
  createdDraft?: JmapCreatedDraft; mayHaveCreated?: boolean;
}
interface CoreError { code?: string; }

export class NativeJmapAccountCore implements JmapAccountCore {
  private async request(input: Request): Promise<Reply> {
    let reply: Reply;
    try { reply = JSON.parse(await jmapAccountRequest(JSON.stringify(input))) as Reply; }
    catch (error) {
      if (input.operation === 'createDraft') {
        if ((error as CoreError).code === 'NATIVE_LIMIT') { throw new JmapDraftError('requestTooLarge', false); }
        throw new JmapDraftError('draftOutcomeUnknown', true);
      }
      throw new JmapError('network');
    }
    if (reply.error !== undefined) {
      if (reply.mayHaveCreated !== undefined) { throw new JmapDraftError(reply.error, reply.mayHaveCreated); }
      throw new JmapError(reply.error);
    }
    return reply;
  }
  async connect(sessionUrl: string, authorization: string): Promise<JmapConnection> {
    const reply = await this.request({ operation: 'connect', sessionUrl, authorization });
    if (reply.session === undefined || reply.maxRequestBytes === undefined) { throw new JmapError('invalidResponse'); }
    return { session: reply.session, maxRequestBytes: reply.maxRequestBytes };
  }
  async mailboxes(sessionUrl: string, authorization: string, accountId: string): Promise<JmapMailbox[]> {
    const reply = await this.request({ operation: 'mailboxes', sessionUrl, authorization, accountId });
    if (reply.mailboxes === undefined) { throw new JmapError('invalidResponse'); }
    return reply.mailboxes;
  }
  async emailPage(sessionUrl: string, authorization: string, accountId: string, mailboxId: string,
    position: number, queryState?: string): Promise<JmapEmailPage> {
    const reply = await this.request({ operation: 'emailPage', sessionUrl, authorization, accountId,
      mailboxId, position, queryState });
    if (reply.page === undefined) { throw new JmapError('invalidResponse'); }
    return reply.page;
  }
  async getEmails(sessionUrl: string, authorization: string, accountId: string, emailIds: string[],
    includeBody: boolean): Promise<JmapEmailSnapshot> {
    const reply = await this.request({ operation: 'getEmails', sessionUrl, authorization, accountId, emailIds, includeBody });
    if (reply.messages === undefined) { throw new JmapError('invalidResponse'); }
    return reply.messages;
  }
  async setKeyword(sessionUrl: string, authorization: string, accountId: string, emailId: string,
    keyword: JmapKeyword, enabled: boolean): Promise<string> {
    const reply = await this.request({ operation: 'setKeyword', sessionUrl, authorization, accountId, emailId, keyword, enabled });
    if (reply.state === undefined) { throw new JmapError('invalidResponse'); }
    return reply.state;
  }
  async archiveEmail(sessionUrl: string, authorization: string, accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    const reply = await this.request({ operation: 'archiveEmail', sessionUrl, authorization, accountId, emailId });
    if (reply.undo === undefined) { throw new JmapError('invalidResponse'); }
    return reply.undo;
  }
  async undoArchive(sessionUrl: string, authorization: string, undo: JmapArchiveUndo): Promise<void> {
    const reply = await this.request({ operation: 'undoArchive', sessionUrl, authorization, accountId: undo.accountId, undo });
    if (reply.state === undefined) { throw new JmapError('invalidResponse'); }
  }
  async createDraft(sessionUrl: string, authorization: string, accountId: string, draft: JmapDraft): Promise<JmapCreatedDraft> {
    const reply = await this.request({ operation: 'createDraft', sessionUrl, authorization, accountId, draft });
    if (reply.createdDraft === undefined) { throw new JmapDraftError('draftOutcomeUnknown', true); }
    return reply.createdDraft;
  }
}
