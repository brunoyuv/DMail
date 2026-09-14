// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { smtpAccountRequest } from 'libthunderbird.so';
interface Request {
  operation: string; endpoint: string; username: string; password: string;
  from: string; to: string[]; cc: string[]; bcc: string[]; subject: string; text: string; id: string; date: number;
}
interface Reply { accepted?: boolean; error?: string; }
function request(mode: string, startTLS: boolean = false): Request {
  return { operation: 'send', endpoint: startTLS ? 'smtp://localhost:9772' : 'smtps://localhost:9771',
    username: mode, password: 'fixture-password', from: 'sender@example.test',
    to: ['reader@example.test'], cc: ['copy@example.test'], bcc: ['hidden@example.test'],
    subject: mode === 'success' ? 'Hello 鸿蒙 📬'.repeat(12) : 'Hello 鸿蒙 📬', text: 'First line\n.\n..dot\r\nLast 鸿蒙 📬',
    id: '7adc6f52-e9bb-4fe2-9c52-6fbd9f399cc6', date: 1789257600000 };
}
async function run(input: Request): Promise<Reply> { return JSON.parse(await smtpAccountRequest(JSON.stringify(input))) as Reply; }
export default function smtpTests() {
  describe('OriginalSwiftSMTP', () => {
    it('implicit_tls_one_transaction_multiple_recipients', 0, async () => { expect((await run(request('success'))).accepted).assertTrue(); });
    it('starttls_reissues_ehlo_before_credentials', 0, async () => { expect((await run(request('starttls', true))).accepted).assertTrue(); });
    it('quit_disconnect_does_not_undo_data_acceptance', 0, async () => { expect((await run(request('quit-drop'))).accepted).assertTrue(); });
    it('recipient_rejection_sends_no_data', 0, async () => { expect((await run(request('recipient-reject'))).error).assertEqual('rejected'); });
    it('authentication_rejection', 0, async () => { expect((await run(request('auth-reject'))).error).assertEqual('authenticationRequired'); });
    it('disconnect_after_data_is_unconfirmed', 0, async () => { expect((await run(request('drop'))).error).assertEqual('deliveryUnconfirmed'); });
    it('explicit_data_rejection_is_not_acceptance', 0, async () => { expect((await run(request('data-reject'))).error).assertEqual('rejected'); });
    it('timeout_after_data_is_unconfirmed', 0, async () => { expect((await run(request('timeout'))).error).assertEqual('deliveryUnconfirmed'); });
    it('concurrent_duplicate_submission_is_blocked', 0, async () => {
      const replies = await Promise.all([run(request('concurrent')), run(request('concurrent'))]);
      expect(replies.filter(reply => reply.accepted === true).length).assertEqual(1);
      expect(replies.filter(reply => reply.error === 'deliveryUnconfirmed').length).assertEqual(1);
    });
    it('header_injection_rejected_before_connect', 0, async () => { const input = request('invalid'); input.subject = 'hi\r\nBcc: bad@example.test'; expect((await run(input)).error).assertEqual('invalidMessage'); });
    it('invalid_recipient_rejected_before_connect', 0, async () => { const input = request('invalid'); input.to = ['bad@example.test>\r\nDATA']; expect((await run(input)).error).assertEqual('invalidMessage'); });
    it('untrusted_host_rejected_before_credentials', 0, async () => { const input = request('untrusted'); input.endpoint = 'smtps://127.0.0.1:9771'; expect((await run(input)).accepted === true).assertFalse(); });
  });
}
