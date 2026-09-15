// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { request } from 'libnetworktest.so';
import accountCoreTests from './AccountCore.test';
import readerCoreTests from './ReaderCore.test';
import writeCoreTests from './WriteCore.test';
import draftCoreTests from './DraftCore.test';
interface Reply { status: number; body: string; errorCode: number; errorMessage: string; }
async function fetch(url: string, cancelAfterMs?: number): Promise<Reply> {
  const reply = JSON.parse(await request(JSON.stringify({ url, cancelAfterMs }))) as Reply;
  console.info(`NETWORK_PROBE ${url} status=${reply.status} code=${reply.errorCode} error=${reply.errorMessage}`);
  return reply;
}
interface JmapSnapshot {
  username: string; mailboxNames: string[]; subjects: string[];
  senders: string[]; received: number[]; threadCount: number;
}
async function jmap(scenario: string): Promise<Reply> {
  const reply = JSON.parse(await request(JSON.stringify({ jmap: scenario }))) as Reply;
  console.info(`JMAP_PROBE ${scenario} code=${reply.errorCode} error=${reply.errorMessage}`);
  return reply;
}
export default function networkTests(): void {
  accountCoreTests();
  readerCoreTests();
  writeCoreTests();
  draftCoreTests();
  describe('SwiftFoundationNetworking', () => {
    it('native_urlsession_http', 0, async () => {
      const reply = await fetch('http://127.0.0.1:9660/plain');
      expect(reply.errorCode).assertEqual(0);
      expect(reply.status).assertEqual(200);
      expect(reply.body).assertEqual('NATIVE_HTTP_OK');
    });
    it('native_urlsession_app_scoped_trusted_tls', 0, async () => {
      const reply = await fetch('https://localhost:9661/trusted');
      expect(reply.errorCode).assertEqual(0);
      expect(reply.status).assertEqual(200);
      expect(reply.body).assertEqual('NATIVE_TLS_OK');
      // Repeated short-lived TLS sessions exercise native connection teardown.
      for (let index = 0; index < 20; index++) {
        const repeated = await fetch('https://localhost:9661/trusted');
        expect(repeated.errorCode).assertEqual(0);
        expect(repeated.body).assertEqual('NATIVE_TLS_OK');
      }
    });
    it('native_urlsession_rejects_untrusted_and_wrong_hostname', 0, async () => {
      const untrusted = await fetch('https://127.0.0.1:9662/untrusted');
      expect(untrusted.status).assertEqual(0);
      expect(untrusted.errorMessage.toLowerCase().includes('certificate')).assertTrue();
      const mismatch = await fetch('https://127.0.0.1:9663/wrong-host');
      expect(mismatch.status).assertEqual(0);
      expect(mismatch.errorMessage.toLowerCase().includes('certificate')).assertTrue();
    });
    it('native_urlsession_task_cancellation', 0, async () => {
      const reply = await fetch('http://127.0.0.1:9660/cancel', 500);
      expect(reply.errorCode).assertEqual(-999);
      expect(reply.status).assertEqual(0);
    });
    it('native_urlsession_obeys_cleartext_policy', 0, async () => {
      const reply = await fetch('http://localhost:9660/blocked');
      expect(reply.status).assertEqual(0);
      expect(reply.errorCode !== 0).assertTrue();
    });
    it('native_urlsession_system_trust', 0, async () => {
      const reply = await fetch('https://example.com/');
      expect(reply.errorCode).assertEqual(0);
      expect(reply.status).assertEqual(200);
      expect(reply.body.includes('Example Domain')).assertTrue();
    });
  });
  describe('OriginalThunderbirdJMAP', () => {
    it('original_client_reads_upstream_fixture_messages', 0, async () => {
      const reply = await jmap('read');
      expect(reply.errorCode).assertEqual(0);
      const snapshot = JSON.parse(reply.body) as JmapSnapshot;
      expect(snapshot.username).assertEqual('user@example.com');
      expect(snapshot.mailboxNames.length).assertEqual(6);
      expect(snapshot.mailboxNames[0]).assertEqual('Inbox');
      expect(snapshot.mailboxNames[5]).assertEqual('Trash');
      expect(snapshot.subjects).assertDeepEquals(['Test email', 'Re: Test']);
      expect(snapshot.senders).assertDeepEquals(['user@example.com', 'recipient@example.com']);
      expect(snapshot.received).assertDeepEquals([1751057580, 1751123625]);
      expect(snapshot.threadCount).assertEqual(2);
    });
    it('original_client_rejects_unauthorized_session', 0, async () => {
      const reply = await jmap('unauthorized');
      expect(reply.errorCode).assertEqual(-1013);
    });
    it('original_client_rejects_malformed_method_response', 0, async () => {
      const reply = await jmap('malformed');
      expect(reply.errorCode).assertEqual(-1016);
    });
    it('original_client_changes_only_fixture_mailbox', 0, async () => {
      const reply = await jmap('mailboxChanges');
      expect(reply.errorCode).assertEqual(0);
      expect(reply.body).assertEqual('NATIVE_JMAP_MAILBOX_CHANGES_OK');
    });
  });
}
