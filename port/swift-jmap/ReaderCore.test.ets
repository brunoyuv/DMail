// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { JmapClient, JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';
import { HarmonyJmapTransport } from '../../../main/ets/mail/jmap/HarmonyJmapTransport';
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer fixture-reader-token'; }
}
function client(): JmapClient {
  return new JmapClient('https://localhost:9661/reader/session', new HarmonyJmapTransport(), new Credentials());
}
const account = 'reader_account';
async function readError(id: string): Promise<string> {
  try { await client().readEmail(account, id); } catch (error) { return (error as JmapError).code; }
  return 'NO_ERROR';
}
export default function readerCoreTests(): void {
  describe('NativeReaderIntegration', () => {
    it('native_pages_advance_over_deleted_ids_and_preserve_query_order', 0, async () => {
      const reader = client();
      const first = await reader.emailPage(account, 'paged');
      expect(first.emails.length).assertEqual(1); expect(first.emails[0].id).assertEqual('first');
      expect(first.notFound[0]).assertEqual('deleted'); expect(first.nextPosition).assertEqual(2);
      expect(first.total).assertEqual(3); expect(first.emailState).assertEqual('emails_1');
      const last = await reader.emailPage(account, 'paged', 2, first.queryState);
      expect(last.emails[0].id).assertEqual('last'); expect(last.nextPosition).assertEqual(null);
      const ordered = await reader.emailPage(account, 'ordered');
      expect(ordered.emails[0].id).assertEqual('first'); expect(ordered.emails[1].id).assertEqual('last');
      expect(ordered.emails[0].textBody).assertEqual(null);
    });
    it('native_pages_handle_unknown_totals_and_reject_changed_queries', 0, async () => {
      const reader = client();
      const short = await reader.emailPage(account, 'unknown');
      expect(short.total).assertEqual(null); expect(short.nextPosition).assertEqual(1);
      const end = await reader.emailPage(account, 'unknown', 1, short.queryState);
      expect(end.emails.length).assertEqual(0); expect(end.emailState).assertEqual(null);
      expect(end.nextPosition).assertEqual(null);
      for (const mailbox of ['changed', 'wrongPosition']) {
        let code = 'NO_ERROR';
        try { await reader.emailPage(account, mailbox, 0, 'query_1'); }
        catch (error) { code = (error as JmapError).code; }
        expect(code).assertEqual('queryChanged');
      }
    });
    it('native_reader_decodes_original_email_body_values_and_metadata', 0, async () => {
      const mail = await client().readEmail(account, 'first');
      expect(mail !== null).assertTrue();
      if (!mail) { return; }
      expect(mail.textBody).assertEqual('Hello 世界\n\nSecond part');
      expect(mail.bodyTruncated).assertTrue(); expect(mail.bodyEncodingProblem).assertTrue();
      expect(mail.htmlBody).assertEqual('<h1>JMAP HTML 世界</h1>');
      expect(mail.hasHtmlBody).assertTrue(); expect(mail.hasAttachment).assertTrue();
      expect(mail.mailboxIds.join(',')).assertEqual('inbox,label');
      expect(mail.keywords.includes('$custom')).assertTrue();
      expect(mail.replyTo[0].email).assertEqual('reply@example.test');
      expect(mail.receivedAt).assertEqual(Date.parse('2026-09-13T08:12:34.125Z'));
      expect(mail.threadId).assertEqual('thread_first'); expect(mail.messageIds.length).assertEqual(1);
    });
    it('native_reader_keeps_html_only_and_deleted_messages_explicit', 0, async () => {
      const reader = client();
      const html = await reader.readEmail(account, 'html');
      expect(html !== null).assertTrue();
      if (html) {
        expect(html.htmlBody).assertEqual('<h1>JMAP HTML 世界</h1>');
        expect(html.textBody).assertEqual(null); expect(html.hasHtmlBody).assertTrue();
        expect(html.bodyTruncated).assertFalse();
      }
      expect(await reader.readEmail(account, 'missing')).assertEqual(null);
    });
    it('native_reader_rejects_incomplete_conflicting_or_oversized_data', 0, async () => {
      for (const id of ['badbody', 'duplicate', 'badDate']) { expect(await readError(id)).assertEqual('invalidResponse'); }
      expect(await readError('tooLarge')).assertEqual('responseTooLarge');
      const large = await client().readEmail(account, 'long');
      expect(large?.id).assertEqual('long');
      expect(large?.textBody).assertEqual('界'.repeat(40000) + '\n\nSecond part');
    });
    it('native_reader_repeated_completion_and_session_cancellation', 0, async () => {
      const reader = client();
      for (let i = 0; i < 12; i++) {
        expect((await reader.readEmail(account, 'first'))?.textBody).assertEqual('Hello 世界\n\nSecond part');
      }
    });
  });
}
