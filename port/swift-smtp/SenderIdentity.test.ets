// Native bridge preflight only: these tests return before any network connection.
import { describe, it, expect } from '@ohos/hypium';
import { OutgoingDraft, SmtpSettings, SmtpError, submitMail } from '../../../main/ets/mail/smtp/NativeSmtpClient';

export default function tests(): void {
  describe('SenderIdentity', () => {
    it('separate_unicode_sender_name_reaches_swift_and_header_injection_is_rejected', 0, async () => {
      const settings = new SmtpSettings();
      settings.endpoint = 'smtps://smtp.example.test'; settings.username = 'separate-server-login';
      const draft = new OutgoingDraft();
      draft.id = '7adc6f52-e9bb-4fe2-9c52-6fbd9f399cc6'; draft.date = 1789257600000;
      draft.to = 'reader@example.test'; draft.subject = 'Synthetic sender identity'; draft.text = 'Synthetic body';
      for (const name of ['', '李明 / Zoë 📬', '中'.repeat(200), 'Doe, Jane <Team>']) {
        draft.senderName = name;
        expect((await submitMail(settings, 'sender@example.test', draft, true)).accepted).assertFalse();
      }
      for (const name of ['Name\r\nBcc: attacker@example.test', 'Name\n', '\tName', 'Name\u0000', 'x'.repeat(801)]) {
        draft.senderName = name;
        let code = '';
        try { await submitMail(settings, 'sender@example.test', draft, true); }
        catch (error) { code = (error as SmtpError).code; }
        expect(code).assertEqual('invalidMessage');
      }
    });
  });
}
