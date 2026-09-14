import { describe, it, expect } from '@ohos/hypium';
import { oauthRequest } from 'libthunderbird.so';
import { NativeBrowserOAuth, OAuthRegistration, BrowserAuthorization, BrowserOAuthError } from '../../../main/ets/mail/oauth/NativeBrowserOAuth';

function registration(provider: 'google' | 'microsoft'): OAuthRegistration {
  return { provider: provider, clientID: 'synthetic-native-test-client',
    redirectURI: `org.thunderbird.harmony.imaptest:/oauth/${provider}` };
}
function field(authorization: BrowserAuthorization, name: string): string {
  const match = authorization.url.match(new RegExp(`[?&]${name}=([^&]*)`));
  if (!match) { throw new Error('Missing authorization field'); }
  return decodeURIComponent(match[1]);
}
async function errorCode(operation: () => Promise<void>): Promise<string> {
  try { await operation(); return 'unexpectedSuccess'; }
  catch (error) { return (error as BrowserOAuthError).code; }
}
export default function tests(): void {
  describe('NativeBrowserOAuth', () => {
    const oauth = new NativeBrowserOAuth();
    it('google_native_bridge_uses_original_pkce', 0, async () => {
      const config = registration('google');
      const authorization = await oauth.begin(config, 'identity@example.test');
      try {
        expect(authorization.url.startsWith('https://accounts.google.com/o/oauth2/v2/auth?')).assertTrue();
        expect(field(authorization, 'client_id')).assertEqual(config.clientID);
        expect(field(authorization, 'redirect_uri')).assertEqual(config.redirectURI);
        expect(field(authorization, 'scope')).assertEqual('https://mail.google.com/');
        expect(field(authorization, 'code_challenge_method')).assertEqual('S256');
        expect(field(authorization, 'code_challenge').length).assertEqual(43);
        expect(field(authorization, 'state').length).assertEqual(43);
        expect(field(authorization, 'access_type')).assertEqual('offline');
        expect(authorization.expiresAt > Date.now() / 1000).assertTrue();
        expect(authorization.url.includes('client_secret')).assertFalse();
      } finally { await oauth.cancel(authorization.id); }
    });
    it('microsoft_requests_delegated_imap_smtp_and_refresh', 0, async () => {
      const authorization = await oauth.begin(registration('microsoft'), 'identity@example.test');
      try {
        expect(authorization.url.startsWith('https://login.microsoftonline.com/common/oauth2/v2.0/authorize?')).assertTrue();
        const scopes = field(authorization, 'scope').split(' ');
        expect(scopes.includes('https://outlook.office.com/IMAP.AccessAsUser.All')).assertTrue();
        expect(scopes.includes('https://outlook.office.com/SMTP.Send')).assertTrue();
        expect(scopes.includes('offline_access')).assertTrue();
      } finally { await oauth.cancel(authorization.id); }
      const personal = registration('microsoft'); personal.microsoftPersonalOnly = true;
      const personalAuth = await oauth.begin(personal, 'identity@example.test');
      try { expect(personalAuth.url.startsWith('https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?')).assertTrue(); }
      finally { await oauth.cancel(personalAuth.id); }
    });
    it('bad_callback_does_not_claim_session_and_cancel_prevents_exchange', 0, async () => {
      const config = registration('google');
      const authorization = await oauth.begin(config, 'identity@example.test');
      const callback = `${config.redirectURI}?state=${field(authorization, 'state')}&code=synthetic`;
      try {
        expect(await errorCode(async () => { await oauth.complete(authorization.id, callback.replace('/google?', '/other?')); })).assertEqual('invalidCallback');
        expect(await errorCode(async () => { await oauth.complete(authorization.id, callback.replace(field(authorization, 'state'), 'wrong')); })).assertEqual('stateMismatch');
        await oauth.cancel(authorization.id);
        expect(await errorCode(async () => { await oauth.complete(authorization.id, callback); })).assertEqual('expiredSession');
      } finally { await oauth.cancel(authorization.id); }
    });
    it('denial_consumes_session_and_bridge_rejects_invalid_configuration', 0, async () => {
      const config = registration('microsoft');
      const authorization = await oauth.begin(config, 'identity@example.test');
      const callback = `${config.redirectURI}?state=${field(authorization, 'state')}&error=access_denied`;
      try {
        expect(await errorCode(async () => { await oauth.complete(authorization.id, callback); })).assertEqual('authorizationDenied');
        expect(await errorCode(async () => { await oauth.complete(authorization.id, callback); })).assertEqual('expiredSession');
        expect((await oauthRequest('{"operation":"begin"}')).includes('invalidConfiguration')).assertTrue();
        config.redirectURI = 'http://example.test/callback';
        expect(await errorCode(async () => { await oauth.begin(config, 'identity@example.test'); })).assertEqual('invalidConfiguration');
      } finally { await oauth.cancel(authorization.id); }
    });
  });
}
