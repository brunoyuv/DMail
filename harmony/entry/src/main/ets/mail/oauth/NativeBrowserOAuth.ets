// MPL-2.0: https://mozilla.org/MPL/2.0/
import { oauthRequest } from 'libthunderbird.so';

export type MailOAuthProvider = 'google' | 'microsoft';
// Only actual provider registrations belong here; no embedded client secret.
export interface OAuthRegistration {
  provider: MailOAuthProvider;
  clientID: string;
  redirectURI: string;
  microsoftPersonalOnly?: boolean;
}
export interface BrowserAuthorization {
  id: string;
  url: string;
  expiresAt: number; // Unix seconds, matching the native core.
}
export interface OAuthTokens {
  accessToken: string;
  refreshToken?: string;
  expiresAt: number;
  scope?: string;
}
interface OAuthInput {
  operation: string;
  microsoftPersonalOnly?: boolean;
  provider?: MailOAuthProvider;
  clientID?: string;
  redirectURI?: string;
  email?: string;
  id?: string;
  callback?: string;
  refreshToken?: string;
}
interface OAuthReply {
  authorization?: BrowserAuthorization;
  tokens?: OAuthTokens;
  cancelled?: boolean;
  error?: string;
}
export class BrowserOAuthError extends Error {
  code: string;
  constructor(code: string) { super(code); this.code = code; }
}
export class NativeBrowserOAuth {
  private async request(input: OAuthInput): Promise<OAuthReply> {
    const reply = JSON.parse(await oauthRequest(JSON.stringify(input))) as OAuthReply;
    if (reply.error) { throw new BrowserOAuthError(reply.error); }
    return reply;
  }

  async begin(registration: OAuthRegistration, email: string): Promise<BrowserAuthorization> {
    const reply = await this.request({ operation: 'begin', provider: registration.provider,
      clientID: registration.clientID, redirectURI: registration.redirectURI,
      microsoftPersonalOnly: registration.microsoftPersonalOnly, email: email.trim() });
    if (!reply.authorization) { throw new BrowserOAuthError('invalidConfiguration'); }
    return reply.authorization;
  }

  async complete(id: string, callback: string): Promise<OAuthTokens> {
    const reply = await this.request({ operation: 'callback', id: id, callback: callback });
    if (!reply.tokens) { throw new BrowserOAuthError('invalidTokenResponse'); }
    return reply.tokens;
  }

  async refresh(registration: OAuthRegistration, refreshToken: string): Promise<OAuthTokens> {
    const reply = await this.request({ operation: 'refresh', provider: registration.provider,
      clientID: registration.clientID, redirectURI: registration.redirectURI,
      microsoftPersonalOnly: registration.microsoftPersonalOnly, refreshToken: refreshToken });
    if (!reply.tokens) { throw new BrowserOAuthError('invalidTokenResponse'); }
    return reply.tokens;
  }

  async cancel(id: string): Promise<void> {
    const reply = await this.request({ operation: 'cancel', id: id });
    if (!reply.cancelled) { throw new BrowserOAuthError('invalidCallback'); }
  }
}
