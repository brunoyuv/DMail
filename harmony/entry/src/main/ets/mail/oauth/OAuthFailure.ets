// MPL-2.0: https://mozilla.org/MPL/2.0/
// Display only allowlisted stages/codes; never Error.message or provider text.
export function oauthFailureLabel(stage: string): string {
  if (stage === 'listener') { return 'oauth_error_listener'; }
  if (stage === 'request') { return 'oauth_error_request'; }
  if (stage === 'browser') { return 'oauth_error_browser'; }
  if (stage === 'callback') { return 'oauth_error_callback'; }
  if (stage === 'token') { return 'oauth_error_token'; }
  if (stage === 'mail') { return 'oauth_error_mail'; }
  if (stage === 'storage') { return 'oauth_error_storage'; }
  return 'oauth_signin_error';
}

export function oauthFailureCode(code: string): string {
  const known: string[] = ['network', 'rejected', 'responseTooLarge', 'redirectRejected',
    'invalid_client', 'invalid_grant', 'invalid_request', 'unauthorized_client', 'invalid_scope', 'access_denied',
    'invalidConfiguration', 'invalidCallback', 'stateMismatch', 'expiredSession', 'authorizationDenied',
    'tooManySessions', 'invalidTokenResponse', 'unauthorized', 'authenticationFailed', 'invalidResponse',
    'authenticationRequired', 'certificate', 'unsafeEndpoint', 'invalidArgument', 'forbidden',
    'tls', 'timeout', 'unsupported'];
  return known.includes(code) ? code : 'unknown';
}
