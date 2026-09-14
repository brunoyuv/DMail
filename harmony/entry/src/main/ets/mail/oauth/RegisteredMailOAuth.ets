// MPL-2.0: https://mozilla.org/MPL/2.0/
import { MailOAuthProvider, OAuthRegistration, OAuthTokens } from './NativeBrowserOAuth';

export interface SavedOAuthLogin {
  registration: OAuthRegistration;
  username: string;
  tokens: OAuthTokens;
}

export class RegisteredMailOAuth {
  // Build-time opt-in for experimental Google browser login. This gates new
  // sign-in/reconnect only; saved token validation and refresh remain compatible.
  static readonly googleBrowserSignInEnabled: boolean = false;

  // Public client IDs from registrations created by the user, never secrets.
  static clientID(provider: MailOAuthProvider): string {
    return provider === 'google' ? '883149639454-r1c1m28d0tatqkcn2b55qes9aossu5p6.apps.googleusercontent.com' :
      '5a498739-1838-4bd9-ac87-bb65152dbc1b';
  }
  static incoming(provider: MailOAuthProvider): string {
    return provider === 'google' ? 'imaps://imap.gmail.com:993' : 'imaps://outlook.office365.com:993';
  }
  static outgoing(provider: MailOAuthProvider): string {
    return provider === 'google' ? 'smtp://smtp.gmail.com:587' : 'smtp://smtp-mail.outlook.com:587';
  }
  static allowsOutgoing(provider: MailOAuthProvider, endpoint: string): boolean {
    // Exact destinations keep bearer credentials bound to the registered
    // provider. Gmail documents implicit TLS on 465 and STARTTLS on 587.
    // https://developers.google.com/workspace/gmail/imap/imap-smtp
    return endpoint === RegisteredMailOAuth.outgoing(provider) ||
      (provider === 'google' && endpoint === 'smtps://smtp.gmail.com:465');
  }
  static valid(login: SavedOAuthLogin): boolean {
    const provider = login.registration?.provider;
    const tokens = login.tokens;
    return (provider === 'google' || provider === 'microsoft') &&
      login.registration.clientID === RegisteredMailOAuth.clientID(provider) &&
      (provider !== 'microsoft' || (login.registration.microsoftPersonalOnly === true &&
        login.registration.redirectURI === 'http://127.0.0.1:49152/oauth2redirect')) &&
      /^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}\/oauth2redirect$/.test(login.registration.redirectURI) &&
      typeof login.username === 'string' && login.username.length > 0 && login.username.length <= 512 &&
      !/[\x00-\x1f\x7f]/.test(login.username) && tokens !== undefined &&
      /^[\x21-\x7e]{1,32768}$/.test(tokens.accessToken) &&
      (tokens.refreshToken === undefined || /^[\x21-\x7e]{1,32768}$/.test(tokens.refreshToken)) &&
      Number.isFinite(tokens.expiresAt) && tokens.expiresAt > 0;
  }
}
