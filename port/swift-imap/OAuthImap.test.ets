import { describe, it, expect } from '@ohos/hypium';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

class OAuthFixtureCredentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer synthetic-oauth-token'; }
}
export default function tests(): void {
  describe('NativeImapOAuth', () => {
    for (const port of [9761, 9765]) {
      it(`reads_mail_using_xoauth2_${port}`, 0, async () => {
        const client = new NativeImapClient(`imaps://localhost:${port}`, new OAuthFixtureCredentials(), 'oauth-reader');
        const session = await client.connect();
        expect(session.accounts[0].name).assertEqual('oauth-reader');
        const mailboxes = await client.mailboxes('default');
        const inbox = mailboxes.find((box) => box.role === 'inbox');
        expect(inbox !== undefined).assertTrue();
        const page = await client.emailPage('default', inbox!.id);
        expect(page.emails.length).assertEqual(50);
        const message = await client.readEmail('default', page.emails[0].id);
        expect(message?.textBody?.includes('Hello from Thunderbird IMAP')).assertTrue();
      });
    }
    it('rejected_token_finishes_challenge_without_password_fallback', 0, async () => {
      const client = new NativeImapClient('imaps://localhost:9761', new OAuthFixtureCredentials(), 'oauth-reject');
      let code = '';
      try { await client.connect(); } catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('authenticationRequired');
    });
    it('missing_xoauth2_capability_never_sends_token', 0, async () => {
      const client = new NativeImapClient('imaps://localhost:9766', new OAuthFixtureCredentials(), 'oauth-reader');
      let code = '';
      try { await client.connect(); } catch (error) { code = (error as JmapError).code; }
      // The peer never attempted authentication, so replacement credentials
      // cannot be inferred from its missing protocol capability.
      expect(code).assertEqual('network');
    });
  });
}
