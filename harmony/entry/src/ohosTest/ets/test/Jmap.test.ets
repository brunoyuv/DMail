// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { JmapClient, JmapCredentials, JmapHttpRequest, JmapHttpResponse, JmapError, JmapDraft, JmapDraftError, JmapTransport, ParsedEndpoint } from '../support/PrototypeJmapClient';
import { PrototypeRcpTransport } from '../support/PrototypeRcpTransport';

// Only this test HAP maps a virtual HTTPS origin to the synthetic loopback
// fixture. The production client and transport have no insecure-mode setting.
export class FixtureTransport implements JmapTransport {
  private readonly transport: PrototypeRcpTransport = new PrototypeRcpTransport();
  parseUrl(value: string, base?: string): ParsedEndpoint { return this.transport.parseUrl(value, base); }
  async send(input: JmapHttpRequest): Promise<JmapHttpResponse> {
    const parsed = this.parseUrl(input.url);
    if (parsed.origin !== 'https://fixture.example') { throw new Error('Unexpected fixture origin'); }
    const request: JmapHttpRequest = { url: input.url.replace('https://fixture.example', 'http://127.0.0.1:9555'),
      method: input.method, body: input.body, headers: input.headers, maxResponseBytes: input.maxResponseBytes };
    return this.transport.send(request);
  }
}

class FixtureCredentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer fixture-only-token'; }
}

function request(path: string, limit: number = 4096): JmapHttpRequest {
  return { url: `http://127.0.0.1:9555${path}`, method: 'GET', headers: {}, maxResponseBytes: limit };
}

function draft(): JmapDraft {
  return { from: { name: 'Fixture', email: 'sender@example.com' }, to: [{ name: 'Recipient', email: 'to@example.com' }],
    cc: [{ name: '', email: 'cc@example.com' }], bcc: [{ name: '', email: 'bcc@example.com' }],
    replyTo: [{ name: '', email: 'reply@example.com' }], subject: 'Native draft 鸿蒙 📬', textBody: 'Saved draft 鸿蒙 📬\nSecond line',
    inReplyTo: ['parent@example.com'], references: ['root@example.com', 'parent@example.com'] };
}

export default function jmapTests(): void {
  describe('HistoricalJmapPrototype', () => {
    it('discovery_mailboxes_query_and_read_over_native_http', 0, async () => {
      const client = new JmapClient('https://fixture.example/session', new FixtureTransport(), new FixtureCredentials());
      const session = await client.connect();
      expect(session.primaryAccountId).assertEqual('personal');
      const boxes = await client.mailboxes('personal');
      expect(boxes[0].role).assertEqual('inbox');
      const page = await client.emailPage('personal', boxes[0].id);
      expect(page.emails.length).assertEqual(1);
      expect(page.emails[0].subject).assertEqual('Native JMAP fixture');
      const mail = await client.readEmail('personal', page.emails[0].id);
      expect(mail?.textBody).assertEqual('Hello from the fixture. 鸿蒙 📬');
      expect(mail?.replyTo[0].email).assertEqual('reply@example.com');
    });
    it('draft_creation_and_readback_preserve_unicode_over_native_http', 0, async () => {
      const client = new JmapClient('https://fixture.example/session', new FixtureTransport(), new FixtureCredentials());
      const created = await client.createDraft('personal', draft());
      expect(created.id).assertEqual('draft1');
      expect(created.mailboxId).assertEqual('drafts');
      expect(created.size > 0).assertTrue();
      const mail = await client.readEmail('personal', created.id);
      expect(mail?.textBody).assertEqual('Saved draft 鸿蒙 📬\nSecond line');
      expect(mail?.subject).assertEqual('Native draft 鸿蒙 📬');
      expect(mail?.keywords.includes('$draft')).assertTrue();
      expect(mail?.to[0].email).assertEqual('to@example.com');
    });
    it('lost_draft_acknowledgement_is_uncertain_and_not_replayed', 0, async () => {
      await new FixtureTransport().send({ url: 'https://fixture.example/lose-next-draft-response', method: 'POST',
        headers: { Authorization: 'Bearer fixture-only-token' }, maxResponseBytes: 4096 });
      const client = new JmapClient('https://fixture.example/session', new FixtureTransport(), new FixtureCredentials());
      let uncertain = false;
      try { await client.createDraft('personal', draft()); }
      catch (error) { uncertain = error instanceof JmapDraftError && error.mayHaveCreated && error.code === 'draftOutcomeUnknown'; }
      expect(uncertain).assertTrue();
    });
    it('redirect_is_returned_without_following', 0, async () => {
      const result = await new PrototypeRcpTransport().send(request('/redirect'));
      expect(result.status).assertEqual(302);
    });
    it('response_limit_cancels_native_download', 0, async () => {
      let code = '';
      try { await new PrototypeRcpTransport().send(request('/large', 128)); }
      catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('responseTooLarge');
    });
    it('unicode_survives_network_chunk_boundaries', 0, async () => {
      const result = await new PrototypeRcpTransport().send(request('/unicode'));
      expect(result.body).assertEqual('鸿蒙 📬');
    });
    it('authentication_failure_is_classified', 0, async () => {
      const client = new JmapClient('https://fixture.example/unauthorized', new FixtureTransport(), new FixtureCredentials());
      let code = '';
      try { await client.connect(); } catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('authenticationRequired');
    });
    it('untrusted_tls_certificate_is_rejected', 0, async () => {
      const input = request('/session');
      input.url = 'https://127.0.0.1:9556/session';
      let code = '';
      try { await new PrototypeRcpTransport().send(input); } catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('network');
    });
    it('prototype_client_rejects_plain_http', 0, () => {
      let code = '';
      try { new JmapClient('http://127.0.0.1:9555/session', new PrototypeRcpTransport(), new FixtureCredentials()); }
      catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('unsafeEndpoint');
    });
  });
}
