// Isolated loopback-only preview checks. No saved accounts or real mail.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials } from '../../../main/ets/mail/jmap/JmapClient';

class PreviewCredentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(this.mode + ':fixture-password'));
  }
}
function client(mode: string): NativeImapClient {
  return new NativeImapClient('imaps://localhost:9761', new PreviewCredentials(mode));
}
function encoded(value: string): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
export default function tests(): void {
  describe('MessagePreview', () => {
    it('retains_server_previews_and_samples_only_inline_text_with_cache_and_failure_guards', 0, async () => {
      const inbox = encoded(JSON.stringify('INBOX'));
      const sampled = await client('preview-sample').emailPage('default', inbox);
      expect(sampled.emails.length).assertEqual(2);
      expect(sampled.emails[0].preview).assertEqual('An HTML summary & details');
      expect(sampled.emails[1].preview).assertEqual('A plain summary 中文 café 😀');
      expect(sampled.emails.every(mail => mail.textBody === null && mail.htmlBody === null && !mail.keywords.includes('$seen'))).assertTrue();
      const cached = await client('preview-sample').emailPage('default', inbox, 0, undefined, sampled.emails.map(mail => mail.id));
      expect(cached.emails.length).assertEqual(2); expect(cached.emails.every(mail => mail.preview === '')).assertTrue();
      const supplied = await client('preview-server').emailPage('default', inbox);
      expect(supplied.emails[0].preview).assertEqual('Server preview 43 中文');
      const partial = await client('preview-partial').emailPage('default', inbox);
      expect(partial.emails.length).assertEqual(2); expect(partial.emails[0].preview).assertEqual('An HTML summary & details');
      expect(partial.emails[1].preview).assertEqual('');
      const boundaries = await client('preview-utf8-boundary').emailPage('default', inbox);
      expect(boundaries.emails.length).assertEqual(2);
      expect(boundaries.emails.every(mail => mail.preview.startsWith('中文 café 😀 ') && !mail.preview.includes('�'))).assertTrue();
      const malformed = await client('preview-malformed').emailPage('default', inbox);
      expect(malformed.emails.length).assertEqual(2); expect(malformed.emails.every(mail => mail.preview === '')).assertTrue();
      const start = Date.now();
      const stalled = await client('preview-stall').emailPage('default', inbox);
      expect(stalled.emails.length).assertEqual(2); expect(stalled.emails.every(mail => mail.preview === '')).assertTrue();
      expect(Date.now() - start < 5000).assertTrue();
    });
  });
}
