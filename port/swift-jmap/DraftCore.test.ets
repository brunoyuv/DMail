// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { JmapClient, JmapCredentials, JmapDraft, JmapError, JmapDraftError } from '../../../main/ets/mail/jmap/JmapClient';
import { HarmonyJmapTransport } from '../../../main/ets/mail/jmap/HarmonyJmapTransport';
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer fixture-draft-token'; }
}
const account = 'draft_account';
function client(scenario: string): JmapClient {
  return new JmapClient('https://localhost:9661/drafts/' + scenario + '/session', new HarmonyJmapTransport(), new Credentials());
}
function draft(): JmapDraft {
  return { from: { name: 'Author', email: 'author@example.test' },
    to: [{ name: 'Unfinished', email: 'name<unfinished' }], cc: [{ name: 'Cc', email: 'cc@example.test' }],
    bcc: [{ name: 'Bcc', email: 'bcc@example.test' }], replyTo: [{ name: 'Reply', email: 'reply@example.test' }],
    subject: 'Draft 世界', textBody: 'Fixture draft', inReplyTo: ['parent@example.test'], references: ['root@example.test', 'parent@example.test'] };
}
interface Outcome { code: string; uncertain: boolean; }
async function outcome(scenario: string, value: JmapDraft = draft(), accountId: string = account): Promise<Outcome> {
  try { await client(scenario).createDraft(accountId, value); }
  catch (error) { return { code: (error as JmapError).code, uncertain: error instanceof JmapDraftError && error.mayHaveCreated }; }
  return { code: 'NO_ERROR', uncertain: false };
}
export default function draftCoreTests(): void {
  describe('NativeDraftCreation', () => {
    it('native_draft_snapshots_unicode_and_unfinished_recipients', 0, async () => {
      const writer = client('snapshot'); const value = draft(); value.textBody = '界'.repeat(50000);
      const saving = writer.createDraft(account, value);
      value.subject = 'Edited later'; value.textBody = 'Later body'; value.to[0].email = 'changed@example.test';
      const created = await saving;
      expect(created.id).assertEqual('draft_1'); expect(created.blobId).assertEqual('blob_draft_1');
      expect(created.threadId).assertEqual('thread_draft_1'); expect(created.size).assertEqual(150100);
      expect(created.mailboxId).assertEqual('box_drafts'); expect(created.state).assertEqual('v1');
      const saved = await writer.readEmail(account, created.id);
      expect(saved?.subject).assertEqual('Draft 世界'); expect(saved?.textBody).assertEqual('界'.repeat(50000));
    });
    it('native_draft_can_preserve_an_empty_unfinished_message', 0, async () => {
      const value: JmapDraft = { from: null, to: [], cc: [], bcc: [], replyTo: [], subject: '', textBody: '', inReplyTo: [], references: [] };
      const writer = client('empty'); const created = await writer.createDraft(account, value);
      expect((await writer.readEmail(account, created.id))?.textBody).assertEqual('');
    });
    it('native_draft_preflight_rejects_invalid_input_and_denied_destinations', 0, async () => {
      const header = draft(); header.subject = 'Bad\r\nheader';
      const nul = draft(); nul.textBody = 'Bad\u0000body';
      const large = draft(); large.textBody = '界'.repeat(90000);
      const reference = draft(); reference.inReplyTo = ['<invalid>'];
      for (const value of [header, nul, reference]) {
        const result = await outcome('validation', value); expect(result.code).assertEqual('invalidDraft'); expect(result.uncertain).assertFalse();
      }
      expect((await outcome('validation', large)).code).assertEqual('draftTooLarge');
      expect((await outcome('unknown', draft(), 'unknown_account')).code).assertEqual('accountNotFound');
      expect((await outcome('readonly')).code).assertEqual('accountReadOnly');
      for (const scenario of ['missing', 'ambiguous']) { expect((await outcome(scenario)).code).assertEqual('draftsUnavailable'); }
      expect((await outcome('denied')).code).assertEqual('forbidden');
      const limit = await outcome('limit'); expect(limit.code).assertEqual('requestTooLarge'); expect(limit.uncertain).assertFalse();
      const oversized = draft(); oversized.subject = 'x'.repeat(4 * 1024 * 1024);
      const inputLimit = await outcome('inputLimit', oversized);
      expect(inputLimit.code).assertEqual('requestTooLarge'); expect(inputLimit.uncertain).assertFalse();
    });
    it('native_draft_reports_definite_per_object_rejections', 0, async () => {
      const scenarios = ['reject', 'quota', 'large', 'invalid', 'future'];
      const codes = ['forbidden', 'overQuota', 'draftTooLarge', 'invalidDraft', 'draftRejected'];
      for (let i = 0; i < scenarios.length; i++) {
        const result = await outcome(scenarios[i]); expect(result.code).assertEqual(codes[i]); expect(result.uncertain).assertFalse();
      }
    });
    it('native_draft_preserves_uncertain_outcomes_without_replay', 0, async () => {
      for (const scenario of ['lost', 'malformed', 'conflicting', 'method', 'http']) {
        const result = await outcome(scenario); expect(result.code).assertEqual('draftOutcomeUnknown'); expect(result.uncertain).assertTrue();
      }
      expect((await client('lost').readEmail(account, 'draft_1'))?.subject).assertEqual('Draft 世界');
    });
  });
}
