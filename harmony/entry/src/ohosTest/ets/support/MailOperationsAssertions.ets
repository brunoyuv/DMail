// Synthetic native storage/service assertions; never opens network connections.
import { expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { AccountStore } from '../../../main/ets/data/AccountStore';
import { MailCache } from '../../../main/ets/data/MailCache';
import { MailOperations } from '../../../main/ets/mail/MailOperations';
import { JmapService, JmapEmail, JmapMailbox, JmapSession, JmapEmailPage, JmapDraft,
  JmapCreatedDraft, JmapKeyword, JmapArchiveUndo, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

function mail(id: string): JmapEmail {
  return { id, threadId: id, messageIds: [`${id}@example.test`], mailboxIds: ['inbox', 'label'], keywords: [],
    from: [], to: [], replyTo: [], subject: id, preview: 'Synthetic operation', receivedAt: 100,
    hasAttachment: true, attachments: [{ id: '2', name: 'saved.txt', contentType: 'text/plain', size: 12, sizeIsEncoded: false }],
    textBody: 'Retained operation body 中文', htmlBody: '<p>Retained operation body 中文</p>',
    bodyTruncated: false, bodyEncodingProblem: false, hasHtmlBody: true };
}
function box(id: string, role: string | null): JmapMailbox {
  return { id, role, name: id, parentId: null, sortOrder: 0, totalEmails: 0, unreadEmails: 0,
    maySetSeen: true, maySetKeywords: true, mayAddItems: true, mayRemoveItems: true };
}
class OperationClient implements JmapService {
  mode: string = '';
  calls: string[] = [];
  hold: boolean = false;
  private started: () => void = () => {};
  readonly requested: Promise<void> = new Promise<void>(resolve => { this.started = resolve; });
  private completion: (() => void) | null = null;
  release(): void { const completion = this.completion; this.completion = null; if (completion) { completion(); } }
  async connect(): Promise<JmapSession> { throw new Error('Unexpected connect'); }
  async mailboxes(_accountId: string): Promise<JmapMailbox[]> { throw new Error('Unexpected folders'); }
  async emailPage(_accountId: string, _mailboxId: string, _position?: number, _queryState?: string): Promise<JmapEmailPage> { throw new Error('Unexpected page'); }
  async readEmail(_accountId: string, _emailId: string): Promise<JmapEmail | null> { throw new Error('Unexpected body download'); }
  async createDraft(_accountId: string, _draft: JmapDraft): Promise<JmapCreatedDraft> { throw new Error('Unexpected draft'); }
  async setKeyword(_accountId: string, emailId: string, keyword: JmapKeyword, _enabled: boolean): Promise<string> {
    this.calls.push(`flag:${emailId}:${keyword}`);
    this.started();
    if (this.hold) { await new Promise<void>(resolve => { this.completion = resolve; }); }
    if (this.mode !== '') { throw new JmapError(this.mode); }
    return 'acknowledged';
  }
  async archiveEmail(accountId: string, emailId: string): Promise<JmapArchiveUndo> {
    this.calls.push(`archive:${emailId}`);
    if (this.mode !== '') { throw new JmapError(this.mode); }
    return { accountId, emailId, inboxId: 'inbox', archiveId: 'archive', addedArchive: true,
      expectedMailboxIds: ['archive', 'label', 'server-label'] };
  }
  async undoArchive(undo: JmapArchiveUndo): Promise<void> {
    this.calls.push(`undo:${undo.emailId}`);
    if (this.mode !== '') { throw new JmapError(this.mode); }
  }
}

export async function mailOperationsAssertions(store: AccountStore, accountId: string, otherAccountId: string, serverId: string): Promise<void> {
  const client = new OperationClient();
  const refused = mail('operation-refused'); await store.mail.saveEmail(accountId, refused);
  const before = (await store.mail.email(accountId, refused.id))!;
  client.mode = 'forbidden';
  MailOperations.setKeyword(store, client, accountId, serverId, refused, '$flagged');
  expect(MailOperations.pending(accountId, refused.id)).assertTrue();
  expect(MailOperations.overlay(accountId, refused).keywords.includes('$flagged')).assertTrue();
  expect(MailOperations.overlay(otherAccountId, refused).keywords.includes('$flagged')).assertFalse();
  await MailOperations.whenIdle();
  const rejected = (await store.mail.email(accountId, refused.id))!;
  expect(rejected.stateDirty).assertFalse(); expect(rejected.mail.keywords.includes('$flagged')).assertFalse();
  expect(rejected.bodySavedAt).assertEqual(before.bodySavedAt); expect(rejected.savedAt).assertEqual(before.savedAt);
  expect(rejected.mail.textBody).assertEqual(before.mail.textBody);
  expect(MailOperations.notice(accountId)).assertEqual('change_forbidden');
  MailOperations.clearNotices(accountId);

  const uncertain = mail('operation-uncertain'); await store.mail.saveEmail(accountId, uncertain);
  client.mode = 'network';
  MailOperations.setKeyword(store, client, accountId, serverId, uncertain, '$flagged'); await MailOperations.whenIdle();
  expect(await store.mail.email(accountId, uncertain.id) === null).assertTrue();
  const pending = (await store.mail.email(accountId, uncertain.id, true))!;
  expect(pending.stateDirty).assertTrue(); expect(pending.mail.textBody).assertEqual(uncertain.textBody);
  expect(MailOperations.notice(accountId)).assertEqual('change_unconfirmed');
  const attempted = client.calls.length;
  client.mode = '';
  MailOperations.setKeyword(store, client, accountId, serverId, uncertain, '$seen'); await MailOperations.whenIdle();
  expect(client.calls.length).assertEqual(attempted);
  expect((await store.mail.email(accountId, uncertain.id, true))?.stateDirty).assertTrue();
  MailOperations.clearNotices(accountId);

  // An overlapping page or body response may refresh content but must not
  // erase the mutation's dirty marker or replace its captured mutable metadata.
  const inflight = mail('operation-inflight'); await store.mail.saveEmail(accountId, inflight);
  const heldClient = new OperationClient(); heldClient.hold = true;
  MailOperations.setKeyword(store, heldClient, accountId, serverId, inflight, '$flagged');
  await heldClient.requested;
  const inflightRevision = MailCache.mutationRevision();
  try {
    const stale = mail(inflight.id); stale.subject = 'New header while operation is pending';
    stale.keywords = ['$seen']; stale.mailboxIds = ['archive']; stale.textBody = null; stale.htmlBody = null;
    await store.mail.saveView(accountId, 'inbox', [stale]);
    const summary = (await store.mail.email(accountId, inflight.id, true))!;
    expect(summary.stateDirty).assertTrue(); expect(summary.mail.keywords.length).assertEqual(0);
    expect(summary.mail.mailboxIds.join(',')).assertEqual('inbox,label');
    expect(summary.mail.subject).assertEqual(stale.subject); expect(summary.mail.textBody).assertEqual(inflight.textBody);
    stale.textBody = 'New decoded body while operation is pending'; stale.htmlBody = '<p>New decoded body</p>';
    await store.mail.saveEmail(accountId, stale);
    const downloaded = (await store.mail.email(accountId, inflight.id, true))!;
    expect(downloaded.stateDirty).assertTrue(); expect(downloaded.mail.keywords.length).assertEqual(0);
    expect(downloaded.mail.mailboxIds.join(',')).assertEqual('inbox,label');
    expect(downloaded.mail.textBody).assertEqual(stale.textBody);
    heldClient.release(); await MailOperations.whenIdle();
    const saved = (await store.mail.email(accountId, inflight.id))!;
    expect(saved.stateDirty).assertFalse(); expect(saved.mail.keywords.join(',')).assertEqual('$flagged');
    expect(saved.mail.textBody).assertEqual(stale.textBody); expect(saved.bodySavedAt).assertEqual(downloaded.bodySavedAt);
    expect(heldClient.calls.join(',')).assertEqual('flag:operation-inflight:$flagged');
    await store.mail.saveView(accountId, 'inbox', [stale], null, undefined, inflightRevision);
    const latePage = (await store.mail.email(accountId, inflight.id))!;
    expect(latePage.stateDirty).assertFalse(); expect(latePage.mail.keywords.join(',')).assertEqual('$flagged');
    expect(latePage.mail.mailboxIds.join(',')).assertEqual('inbox,label');
    expect(latePage.mail.textBody).assertEqual(stale.textBody);

  } finally { heldClient.release(); await MailOperations.whenIdle(); }

  // Independent message jobs may acknowledge together; both unread-count
  // adjustments must survive the shared cache queue.
  const seenClient = new OperationClient();
  const countBoxes = (await store.mail.boxes(accountId))!;
  const inbox = countBoxes.boxes.find(value => value.id === 'inbox')!; inbox.unreadEmails = 2;
  await store.mail.saveBoxes(accountId, countBoxes.boxes, countBoxes.readOnly);
  const firstSeen = mail('operation-seen-one'), secondSeen = mail('operation-seen-two');
  firstSeen.mailboxIds = ['inbox']; secondSeen.mailboxIds = ['inbox'];
  await store.mail.saveEmail(accountId, firstSeen); await store.mail.saveEmail(accountId, secondSeen);
  MailOperations.setKeyword(store, seenClient, accountId, serverId, firstSeen, '$seen');
  MailOperations.setKeyword(store, seenClient, accountId, serverId, secondSeen, '$seen');
  await MailOperations.whenIdle();
  expect((await store.mail.boxes(accountId))?.boxes.find(value => value.id === 'inbox')?.unreadEmails).assertEqual(0);
  expect((await store.mail.email(accountId, firstSeen.id))?.mail.keywords.includes('$seen')).assertTrue();
  expect((await store.mail.email(accountId, secondSeen.id))?.mail.keywords.includes('$seen')).assertTrue();
  expect(seenClient.calls.length).assertEqual(2);

  const moving = mail('operation-archive'); await store.mail.saveEmail(accountId, moving);
  const moveBefore = (await store.mail.email(accountId, moving.id))!;
  await store.mail.saveView(accountId, 'archive', [], 40, 'archive-query');
  const folders = (await store.mail.boxes(accountId))!;
  if (!folders.boxes.some(value => value.id === 'archive')) { folders.boxes.push(box('archive', 'archive')); }
  await store.mail.saveBoxes(accountId, folders.boxes, folders.readOnly);
  const beforeMoveRevision = MailCache.mutationRevision();
  MailOperations.move(store, client, accountId, serverId, moving, ['archive', 'label']);
  expect(MailOperations.overlay(accountId, moving).mailboxIds.join(',')).assertEqual('archive,label');
  await MailOperations.whenIdle();
  const archived = (await store.mail.email(accountId, moving.id))!;
  expect(archived.mail.mailboxIds.join(',')).assertEqual('archive,label,server-label');
  expect(archived.stateDirty).assertFalse(); expect(archived.mail.textBody).assertEqual(moveBefore.mail.textBody);
  expect(archived.mail.attachments![0].name).assertEqual('saved.txt');
  expect(archived.savedAt).assertEqual(moveBefore.savedAt); expect(archived.bodySavedAt).assertEqual(moveBefore.bodySavedAt);
  const archiveView = (await store.mail.view(accountId, 'archive'))!;
  expect(archiveView.emails.some(value => value.id === moving.id)).assertTrue();
  expect(archiveView.nextPosition).assertEqual(40); expect(archiveView.queryState).assertEqual('archive-query');
  await store.mail.saveView(accountId, 'archive', [], 40, 'archive-query', beforeMoveRevision);
  expect((await store.mail.view(accountId, 'archive'))?.emails.some(value => value.id === moving.id)).assertTrue();

  const undo = MailOperations.undo(accountId)!;
  expect(undo.expectedMailboxIds.join(',')).assertEqual('archive,label,server-label');
  MailOperations.clearNotices(accountId); client.mode = 'stateMismatch';
  MailOperations.move(store, client, accountId, serverId, archived.mail, ['inbox', 'label', 'server-label'], undo);
  await MailOperations.whenIdle();
  expect((await store.mail.email(accountId, moving.id, true))?.stateDirty).assertTrue();
  expect(MailOperations.notice(accountId)).assertEqual('move_conflict');
  expect(client.calls.join(',')).assertEqual('flag:operation-refused:$flagged,flag:operation-uncertain:$flagged,archive:operation-archive,undo:operation-archive');
  expect((await store.mail.cachedMessages(otherAccountId)).some(value => value.mail.id.startsWith('operation-'))).assertFalse();
  MailOperations.clearNotices(accountId);
}

export async function appendSentAssertions(store: AccountStore, accountId: string, context: common.Context): Promise<void> {
  const sent = box('sent', 'sent');
  const folders = (await store.mail.boxes(accountId))!;
  await store.mail.saveBoxes(accountId, folders.boxes.concat(sent), folders.readOnly);
  const existing = mail('sent-existing-dirty'); existing.mailboxIds = ['sent'];
  await store.mail.saveView(accountId, 'sent', [existing], 40, 'saved-sent-query');
  await store.mail.saveEmail(accountId, existing);
  const before = (await store.mail.email(accountId, existing.id))!;
  await store.mail.markDirty(accountId, existing.id);
  const outgoing = mail('local_sent_one'); outgoing.mailboxIds = ['sent']; outgoing.keywords = ['$seen'];
  outgoing.messageIds = ['confirmed-outgoing@example.test'];
  await store.mail.appendSent(accountId, outgoing, sent);
  const duplicate = mail('local_sent_duplicate'); duplicate.mailboxIds = ['sent']; duplicate.keywords = ['$seen'];
  duplicate.messageIds = outgoing.messageIds;
  await store.mail.appendSent(accountId, duplicate, sent);
  await store.close(); await store.open(context);
  const retained = (await store.mail.email(accountId, existing.id, true))!;
  expect(retained.stateDirty).assertTrue(); expect(retained.mail.textBody).assertEqual(before.mail.textBody);
  expect(retained.bodySavedAt).assertEqual(before.bodySavedAt); expect(retained.savedAt).assertEqual(before.savedAt);
  const view = (await store.mail.view(accountId, 'sent', true))!;
  expect(view.emails.length).assertEqual(2); expect(view.nextPosition).assertEqual(40);
  expect(view.queryState).assertEqual('saved-sent-query');
  expect(view.emails.filter(value => value.messageIds.includes(outgoing.messageIds[0])).length).assertEqual(1);
  const saved = (await store.mail.email(accountId, view.emails[0].id))!;
  expect(saved.mail.textBody).assertEqual(outgoing.textBody); expect(saved.bodySavedAt !== null).assertTrue();
  expect((await store.mail.boxes(accountId))?.readOnly).assertEqual(folders.readOnly);
  expect((await store.mail.boxes(accountId))?.roleRevision).assertEqual(2);
}
