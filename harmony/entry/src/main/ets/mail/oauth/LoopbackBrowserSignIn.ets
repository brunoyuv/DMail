// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { BrowserOAuthError, MailOAuthProvider, NativeBrowserOAuth, OAuthTokens, OAuthRegistration } from './NativeBrowserOAuth';
import { LoopbackOAuthListener } from './LoopbackOAuthListener';

// One instance owns one attempt. Keep it alive while the system browser is open,
// and call cancel when account setup is dismissed. Process death starts afresh.
export class LoopbackBrowserSignIn {
  private started: boolean = false;
  private cancelled: boolean = false;
  private settled: boolean = false;
  private exchanging: boolean = false;
  private id: string = '';
  private listener?: LoopbackOAuthListener;
  private oauth: NativeBrowserOAuth;
  private launch: (url: string) => Promise<void>;
  private tokens?: OAuthTokens;
  private failure?: BrowserOAuthError;
  registration?: OAuthRegistration;
  // Safe diagnostic stage only. Never retain the callback URL or provider text.
  failureStage: string = 'listener';
  private resolve: (tokens: OAuthTokens) => void = () => {};
  private reject: (error: BrowserOAuthError) => void = () => {};

  constructor(launch: (url: string) => Promise<void>, oauth: NativeBrowserOAuth = new NativeBrowserOAuth()) {
    this.launch = launch; this.oauth = oauth;
  }

  static forContext(context: common.UIAbilityContext): LoopbackBrowserSignIn {
    return new LoopbackBrowserSignIn(async (url) => { await context.openLink(url); });
  }

  async signIn(provider: MailOAuthProvider, clientID: string, email: string, microsoftPersonalOnly: boolean = false): Promise<OAuthTokens> {
    if (this.started) { throw new BrowserOAuthError('alreadyStarted'); }
    this.started = true;
    const result = new Promise<OAuthTokens>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
    // Cancellation can arrive while listen, native begin, or openLink is pending.
    result.catch(() => {});
    this.listener = new LoopbackOAuthListener((callback) => this.callback(callback),
      () => this.finish(new BrowserOAuthError('expiredSession')), () => this.finish(this.failure));
    try {
      if (this.cancelled) { throw new BrowserOAuthError('cancelled'); }
      // Microsoft uses an exact registered loopback URI. Bind it before opening
      // the browser; a busy port must fail, never redirect to another process.
      const redirect = await this.listener.open(600000, provider === 'microsoft' ? 49152 : 0);
      if (this.cancelled) { throw new BrowserOAuthError('cancelled'); }
      if (this.settled) { throw new BrowserOAuthError('expiredSession'); }
      this.registration = { provider: provider, clientID: clientID, redirectURI: redirect,
        microsoftPersonalOnly: microsoftPersonalOnly };
      this.failureStage = 'request';
      const authorization = await this.oauth.begin(this.registration, email);
      this.id = authorization.id;
      if (this.cancelled) { throw new BrowserOAuthError('cancelled'); }
      if (this.settled) { throw new BrowserOAuthError('expiredSession'); }
      this.failureStage = 'browser';
      await Promise.race([this.launch(authorization.url), result.then(() => {})]);
      if (!this.exchanging) { this.failureStage = 'callback'; }
      return await result;
    } finally {
      this.settled = true;
      // Listener/native-session cleanup must not replace completed tokens or
      // the original sign-in/cancellation error. Attempt both independently.
      await this.listener.close().catch(() => {});
      if (this.id !== '') { await this.oauth.cancel(this.id).catch(() => {}); }
    }
  }

  private async callback(callback: string): Promise<boolean> {
    if (this.id === '' || this.cancelled || this.settled || this.exchanging) { return false; }
    this.exchanging = true;
    this.failureStage = 'token';
    try {
      const tokens = await this.oauth.complete(this.id, callback);
      if (this.cancelled || this.settled) { return false; }
      this.tokens = tokens;
    }
    catch (error) {
      const code = (error as BrowserOAuthError).code;
      if (code === 'invalidCallback' || code === 'stateMismatch') {
        this.exchanging = false; this.failureStage = 'callback'; return false;
      }
      this.failure = new BrowserOAuthError(code ?? 'network');
    }
    // The listener sends its generic browser response and closes the port before
    // resolving the caller, which may immediately dismiss the account setup UI.
    return true;
  }

  private finish(error?: BrowserOAuthError): void {
    if (this.settled) { return; }
    this.settled = true;
    if (error) { this.reject(error); }
    else if (this.tokens) { this.resolve(this.tokens); }
    else { this.reject(new BrowserOAuthError('invalidTokenResponse')); }
  }

  cancel(): void {
    this.cancelled = true;
    if (this.started) { this.finish(new BrowserOAuthError('cancelled')); }
    // During startup signIn's finally owns cleanup once the pending open ends.
    if (this.id !== '') {
      this.listener?.close().catch(() => {});
      this.oauth.cancel(this.id).catch(() => {});
    }
  }
}
