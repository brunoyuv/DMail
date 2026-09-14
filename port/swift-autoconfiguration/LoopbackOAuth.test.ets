import { describe, it, expect } from '@ohos/hypium';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { LoopbackOAuthListener } from '../../../main/ets/mail/oauth/LoopbackOAuthListener';
import { NativeBrowserOAuth } from '../../../main/ets/mail/oauth/NativeBrowserOAuth';
import { oauthFailureLabel, oauthFailureCode } from '../../../main/ets/mail/oauth/OAuthFailure';
import { LoopbackBrowserSignIn } from '../../../main/ets/mail/oauth/LoopbackBrowserSignIn';

function authority(uri: string): string { return uri.split('/')[2]; }
function port(uri: string): number { return Number(authority(uri).split(':')[1]); }
function delay(ms: number): Promise<void> { return new Promise<void>((resolve) => { setTimeout(resolve, ms); }); }
async function exchange(uri: string, parts: string[]): Promise<string> {
  const client = socket.constructTCPSocketInstance();
  let body = '';
  let finish: (value: string) => void = () => {};
  let timer = -1;
  const response = new Promise<string>((resolve) => { finish = resolve; });
  client.on('message', (info: socket.SocketMessageInfo) => { body += new util.TextDecoder().decodeToString(new Uint8Array(info.message)); });
  client.on('close', () => { finish(body); });
  client.on('error', () => { finish(body); });
  try {
    timer = setTimeout(() => { finish('TIMEOUT'); }, 5000);
    await client.connect({ address: { address: '127.0.0.1', family: 1, port: port(uri) }, timeout: 1000 });
    for (const part of parts) { await client.send({ data: part }); await delay(10); }
    return await response;
  } finally {
    clearTimeout(timer);
    client.off('message'); client.off('close'); client.off('error');
    try { await client.close(); } catch (_) {}
  }
}
async function canConnect(uri: string): Promise<boolean> {
  const client = socket.constructTCPSocketInstance();
  client.on('error', () => {});
  try { await client.connect({ address: { address: '127.0.0.1', family: 1, port: port(uri) }, timeout: 500 }); return true; }
  catch (_) { return false; }
  finally { client.off('error'); try { await client.close(); } catch (_) {} }
}
export default function tests(): void {
  describe('HarmonyOAuthLoopback', () => {
    it('diagnostics_never_display_arbitrary_error_text', 0, () => {
      expect(oauthFailureCode('invalid_client')).assertEqual('invalid_client');
      expect(oauthFailureCode('private-token@example.test')).assertEqual('unknown');
      expect(oauthFailureLabel('private-token')).assertEqual('oauth_signin_error');
      expect(oauthFailureLabel('token')).assertEqual('oauth_error_token');
      expect(oauthFailureLabel('mail')).assertEqual('oauth_error_mail');
      expect(oauthFailureLabel('storage')).assertEqual('oauth_error_storage');
    });
    it('fragmented_http_callback_is_delivered_once_then_port_closes', 0, async () => {
      let callbacks: string[] = [];
      const listener = new LoopbackOAuthListener(async (callback) => { callbacks.push(callback); return true; }, () => {});
      const uri = await listener.open();
      try {
        expect(uri.startsWith('http://127.0.0.1:')).assertTrue();
        const response = await exchange(uri, ['GET /oauth2redirect?state=synthetic&co', `de=private-code HTTP/1.1\r\nHost: ${authority(uri)}\r\n`, '\r\n']);
        expect(response.startsWith('HTTP/1.1 200 OK')).assertTrue();
        expect(response.includes('private-code')).assertFalse();
        expect(response.includes('Cache-Control: no-store')).assertTrue();
        expect(callbacks.length).assertEqual(1);
        expect(callbacks[0]).assertEqual(`${uri}?state=synthetic&code=private-code`);
        await listener.close();
        expect(await canConnect(uri)).assertFalse();
      } finally { await listener.close(); }
    });
    it('malformed_requests_never_reach_authorization_handler', 0, async () => {
      let count = 0;
      const listener = new LoopbackOAuthListener(async (_) => { count++; return false; }, () => {});
      const uri = await listener.open();
      try {
        for (const request of [
          'POST /oauth2redirect?code=x HTTP/1.1\r\n',
          'GET http://other.test/oauth2redirect?code=x HTTP/1.1\r\n',
          'GET /other?code=x HTTP/1.1\r\n',
          'GET /oauth2redirect?code=x HTTP/1.1\r\nOrigin: https://other.test\r\n',
          'GET /oauth2redirect?code=x HTTP/1.1\r\nHost: other.test\r\n',
          'GET /oauth2redirect?code=x HTTP/1.1\r\nContent-Length: 1\r\n'
        ]) {
          expect((await exchange(uri, [`${request}Host: ${authority(uri)}\r\n\r\n`])).startsWith('HTTP/1.1 400')).assertTrue();
        }
        expect(count).assertEqual(0);
      } finally { await listener.close(); }
    });
    it('native_state_validation_rejects_wrong_callback_then_accepts_denial', 0, async () => {
      const oauth = new NativeBrowserOAuth();
      let id = '';
      let lastError = '';
      const listener = new LoopbackOAuthListener(async (callback) => {
        try { await oauth.complete(id, callback); return true; }
        catch (error) { lastError = error.message; return lastError === 'authorizationDenied'; }
      }, () => {});
      const uri = await listener.open();
      try {
        const authorization = await oauth.begin({ provider: 'google', clientID: 'synthetic-native-client', redirectURI: uri }, 'identity@example.test');
        id = authorization.id;
        const state = authorization.url.match(/[?&]state=([^&]+)/)![1];
        expect((await exchange(uri, [`GET /oauth2redirect?state=wrong&error=access_denied HTTP/1.1\r\nHost: ${authority(uri)}\r\n\r\n`])).startsWith('HTTP/1.1 400')).assertTrue();
        expect(lastError).assertEqual('stateMismatch');
        expect((await exchange(uri, [`GET /oauth2redirect?state=${state}&error=access_denied HTTP/1.1\r\nHost: ${authority(uri)}\r\n\r\n`])).startsWith('HTTP/1.1 200')).assertTrue();
        expect(lastError).assertEqual('authorizationDenied');
      } finally { await oauth.cancel(id); await listener.close(); }
    });
    it('cancellation_and_deadline_close_listening_port', 0, async () => {
      const cancelled = new LoopbackOAuthListener(async (_) => false, () => {});
      const cancelledURI = await cancelled.open();
      await cancelled.close();
      expect(await canConnect(cancelledURI)).assertFalse();
      let expired = false;
      const listener = new LoopbackOAuthListener(async (_) => false, () => { expired = true; });
      const uri = await listener.open(100);
      try {
        await delay(200);
        expect(expired).assertTrue();
        await listener.close();
        expect(await canConnect(uri)).assertFalse();
      } finally { await listener.close(); }
    });
    it('browser_return_delivers_denial_after_closing_socket', 0, async () => {
      let uri = '';
      const signIn = new LoopbackBrowserSignIn(async (authorizationURL) => {
        uri = decodeURIComponent(authorizationURL.match(/[?&]redirect_uri=([^&]+)/)![1]);
        const state = authorizationURL.match(/[?&]state=([^&]+)/)![1];
        await exchange(uri, [`GET /oauth2redirect?state=${state}&error=access_denied HTTP/1.1\r\nHost: ${authority(uri)}\r\n\r\n`]);
      });
      let errorCode = '';
      try { await signIn.signIn('google', 'synthetic-native-client', 'identity@example.test'); }
      catch (error) { errorCode = error.message; }
      expect(errorCode).assertEqual('authorizationDenied');
      expect(signIn.failureStage).assertEqual('token');
      expect(await canConnect(uri)).assertFalse();
    });
    it('browser_launch_failure_and_user_cancel_release_listener', 0, async () => {
      let uri = '';
      const unavailable = new LoopbackBrowserSignIn(async (authorizationURL) => {
        uri = decodeURIComponent(authorizationURL.match(/[?&]redirect_uri=([^&]+)/)![1]);
        throw new Error('browserUnavailable');
      });
      let errorCode = '';
      try { await unavailable.signIn('google', 'synthetic-native-client', 'identity@example.test'); }
      catch (error) { errorCode = error.message; }
      expect(errorCode).assertEqual('browserUnavailable');
      expect(unavailable.failureStage).assertEqual('browser');
      expect(await canConnect(uri)).assertFalse();
      const cancelled = new LoopbackBrowserSignIn(async (authorizationURL) => {
        uri = decodeURIComponent(authorizationURL.match(/[?&]redirect_uri=([^&]+)/)![1]);
        setTimeout(() => { cancelled.cancel(); }, 10);
      });
      try { await cancelled.signIn('google', 'synthetic-native-client', 'identity@example.test'); }
      catch (error) { errorCode = error.message; }
      expect(errorCode).assertEqual('cancelled');
      expect(await canConnect(uri)).assertFalse();
    });
    it('microsoft_uses_registered_port_and_closes_it_after_return', 0, async () => {
      let uri = '';
      const signIn = new LoopbackBrowserSignIn(async (authorizationURL) => {
        uri = decodeURIComponent(authorizationURL.match(/[?&]redirect_uri=([^&]+)/)![1]);
        expect(uri).assertEqual('http://127.0.0.1:49152/oauth2redirect');
        const state = authorizationURL.match(/[?&]state=([^&]+)/)![1];
        await exchange(uri, [`GET /oauth2redirect?state=${state}&error=access_denied HTTP/1.1\r\nHost: ${authority(uri)}\r\n\r\n`]);
      });
      let errorCode = '';
      try { await signIn.signIn('microsoft', 'synthetic-microsoft-client', 'identity@example.test'); }
      catch (error) { errorCode = error.message; }
      expect(errorCode).assertEqual('authorizationDenied');
      expect(signIn.failureStage).assertEqual('token');
      expect(await canConnect(uri)).assertFalse();
    });
    it('occupied_microsoft_callback_port_prevents_browser_launch', 0, async () => {
      const occupied = new LoopbackOAuthListener(async (_) => false, () => {});
      const uri = await occupied.open(600000, 49152);
      let launched = false;
      const signIn = new LoopbackBrowserSignIn(async (_) => { launched = true; });
      let failed = false;
      try {
        try { await signIn.signIn('microsoft', 'synthetic-microsoft-client', 'identity@example.test'); }
        catch (_) { failed = true; }
        expect(failed).assertTrue();
        expect(launched).assertFalse();
        expect(await canConnect(uri)).assertTrue();
      } finally { signIn.cancel(); await occupied.close(); }
      expect(await canConnect(uri)).assertFalse();
    });
  });
}
