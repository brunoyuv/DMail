// Synthetic SMTP and IMAP only; no real mailbox is accessed.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { submitMail, SmtpSettings, OutgoingDraft, SentCopyDestination } from '../../../main/ets/mail/smtp/NativeSmtpClient';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';

class SentCredentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> { return destination(this.mode).authorization; }
}

function settings(mode: string): SmtpSettings {
  const value = new SmtpSettings(); value.endpoint = 'smtps://localhost:9771'; value.username = mode; value.password = 'fixture-password'; return value;
}
function draft(): OutgoingDraft {
  const value = new OutgoingDraft(); value.id = util.generateRandomUUID(); value.date = 1789257600000;
  value.to = 'reader@example.test'; value.cc = 'copy@example.test'; value.bcc = 'hidden@example.test';
  value.subject = 'Sent copy 中文'; value.text = 'Original sent body 日本語';
  value.inReplyTo = ['parent@example.test']; value.references = ['root@example.test', 'parent@example.test']; return value;
}
function destination(mode: string): SentCopyDestination {
  return { sessionUrl: 'imaps://localhost:9773', authorization: 'Basic ' +
    new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(mode + ':fixture-password')) };
}
export default function tests(): void {
  describe('SentCopyNative', () => {
    it('local_validation_requires_no_credentials_or_connection', 0, async () => {
      const value = settings('sent-validate'); value.password = '';
      expect((await submitMail(value, 'sender@example.test', draft(), true, '')).accepted).assertFalse();
    });
    it('successful_submission_saves_one_private_copy_with_original_message_id', 0, async () => {
      const value = draft();
      const result = await submitMail(settings('sent-success'), 'sender@example.test', value, false, undefined, destination('sent-success'));
      expect(result.accepted).assertTrue(); expect(result.sentCopy).assertEqual('saved');
      expect(result.sentMailboxId!.length > 0).assertTrue(); expect(result.messageId.includes('@example.test')).assertTrue();
      expect(result.date).assertEqual(value.date); expect(result.textBody).assertEqual(value.text);
    });
    it('explicit_append_rejection_preserves_smtp_acceptance', 0, async () => {
      const result = await submitMail(settings('sent-reject'), 'sender@example.test', draft(), false, undefined, destination('sent-reject'));
      expect(result.accepted).assertTrue(); expect(result.sentCopy).assertEqual('failed');
    });
    it('lost_append_acknowledgement_is_unconfirmed_without_resending_smtp', 0, async () => {
      const result = await submitMail(settings('sent-drop'), 'sender@example.test', draft(), false, undefined, destination('sent-drop'));
      expect(result.accepted).assertTrue(); expect(result.sentCopy).assertEqual('unconfirmed');
    });
    it('missing_or_ambiguous_special_use_mailbox_does_not_guess_a_folder', 0, async () => {
      for (const mode of ['sent-missing', 'sent-ambiguous', 'sent-conventional-ambiguous']) {
        const result = await submitMail(settings(mode), 'sender@example.test', draft(), false, undefined, destination(mode));
        expect(result.accepted).assertTrue(); expect(result.sentCopy).assertEqual('failed');
        expect(result.sentMailboxId === undefined).assertTrue();
      }
    });
    it('existing_conventional_sent_folder_matches_mailbox_role_and_submission_target', 0, async () => {
      for (const mode of ['sent-conventional', 'sent-nested']) {
        const result = await submitMail(settings(mode), 'sender@example.test', draft(), false, undefined, destination(mode));
        expect(result.accepted).assertTrue(); expect(result.sentCopy).assertEqual('saved');
        const client = new NativeImapClient('imaps://localhost:9773', new SentCredentials(mode));
        const boxes = await client.mailboxes('default');
        const sent = boxes.filter(box => box.role === 'sent');
        expect(sent.length).assertEqual(1); expect(sent[0].id).assertEqual(result.sentMailboxId);
        expect(sent[0].name).assertEqual(mode === 'sent-conventional' ? 'Sent Items' : 'INBOX.Sent');
      }
    });
  });
}
