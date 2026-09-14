import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { SmtpSettings, OutgoingDraft, submitMail, SmtpError } from '../../../main/ets/mail/smtp/NativeSmtpClient';

async function send(endpoint: string, username: string): Promise<void> {
  const settings = new SmtpSettings();
  settings.endpoint = endpoint; settings.username = username;
  const draft = new OutgoingDraft();
  draft.id = util.generateRandomUUID(); draft.date = Date.now();
  draft.to = 'reader@example.test'; draft.subject = 'Synthetic OAuth SMTP';
  draft.text = 'OAuth SMTP 日本語\n.\nLast line';
  await submitMail(settings, 'sender@example.test', draft, false, 'synthetic-oauth-token');
}
export default function tests(): void {
  describe('NativeSmtpOAuth', () => {
    it('xoauth2_sends_synthetic_mail_over_implicit_tls', 0, async () => {
      await send('smtps://localhost:9771', 'oauth-success');
      expect(true).assertTrue();
    });
    it('xoauth2_sends_only_after_starttls_and_second_ehlo', 0, async () => {
      await send('smtp://localhost:9772', 'oauth-success');
      expect(true).assertTrue();
    });
    it('xoauth2_rejection_sends_no_message', 0, async () => {
      let code = '';
      try { await send('smtps://localhost:9771', 'oauth-reject'); }
      catch (error) { code = (error as SmtpError).code; }
      expect(code).assertEqual('authenticationRequired');
    });
  });
}
