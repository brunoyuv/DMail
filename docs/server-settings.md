# Server settings and discovery

The iOS Autoconfiguration module now links into the shared native core. Account
setup calls its bounded HTTPS discovery through Node-API, displays ordered server
proposals and applies a user-selected password configuration. Its implementation
and remaining boundaries are in [the port record](../port/swift-autoconfiguration/README.md).
The signed ARM build was installed on the Pura X on 14 September 2026. Its
public HTTPS discovery and account setup were exercised on the Pura X main-screen
emulator profile (five tests passed); real-provider sign-in on the phone remains
for device testing. The emulator was stopped after each run.

The connected settings flow must preserve separate email identity and server
login, present ordered incoming/outgoing candidates, allow manual overrides, and
make supported authentication/security explicit. Existing encrypted accounts,
SMTP credentials and drafts must survive settings edits. A discovered unsupported
option must never silently become a password login or an unencrypted connection.

Current mail transport supports IMAP with implicit TLS and password login, and
SMTP with implicit TLS/mandatory STARTTLS and LOGIN/PLAIN. Broader compatibility
requires IMAP STARTTLS, authentication selection and browser OAuth with real
provider registrations. POP3, NTLM and GSSAPI are not implemented merely because
the discovery model can describe them. No broad Thunderbird server-compatibility
claim has been established yet.

Email address, incoming username and outgoing username remain separate. Applying
a proposal never sends credentials. Incoming credentials are tested by Connect;
outgoing credentials are stored with the new account before it becomes ready.
The outgoing password reuse switch is visible and can be turned off. The composer
then asks for the separate outgoing password. Failed account creation removes
both credential records through the existing recoverable cleanup path.

On 14 September the user asked about browser authentication. The intended flow is
system-browser authorization, a registered callback to the app, authorization-code
exchange with PKCE, and protected access/refresh token storage. This follows
[OAuth for Native Apps, RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html).
Opening a sign-in URL is only one step: provider registration, callback/state
validation, token refresh and IMAP/SMTP bearer authentication remain unfinished.
No client ID, authorization endpoint or redirect is inferred from a hostname.
Provider-specific OAuth remains unavailable pending those integrations.
