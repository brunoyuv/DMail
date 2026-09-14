// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { JmapClient, JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';
import { HarmonyJmapTransport } from '../../../main/ets/mail/jmap/HarmonyJmapTransport';
import { NativeJmapAccountCore } from '../../../main/ets/mail/jmap/NativeJmapAccountCore';

const origin = 'https://localhost:9661/native/';
class FixtureCredentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer fixture-account-token'; }
}
async function errorFor(path: string, account?: string, authorization: string = 'Bearer fixture-account-token'): Promise<string> {
  const core = new NativeJmapAccountCore();
  try {
    if (account === undefined) { await core.connect(path.startsWith('http') ? path : origin + path, authorization); }
    else { await core.mailboxes(origin + path, authorization, account); }
  } catch (error) { return (error as JmapError).code; }
  return 'NO_ERROR';
}
export default function accountCoreTests(): void {
  describe('NativeAccountIntegration', () => {
    it('configured_session_and_selected_account_use_original_core', 0, async () => {
      const client = new JmapClient(origin + 'custom-session', new HarmonyJmapTransport(), new FixtureCredentials());
      const session = await client.connect();
      expect(session.accounts.length).assertEqual(2);
      expect(session.primaryAccountId).assertEqual('z_selected');
      expect(session.accounts[0].id).assertEqual('a_first');
      const boxes = await client.mailboxes('z_selected');
      expect(boxes.length).assertEqual(6);
      expect(boxes[0].name).assertEqual('Shared Inbox');
      expect(boxes[0].id.startsWith('shared_')).assertTrue();
      expect(boxes[0].parentId).assertEqual(null);
      expect(boxes[0].maySetSeen).assertTrue();
    });
    it('native_account_rejects_bad_auth_endpoint_and_selection', 0, async () => {
      expect(await errorFor('http://localhost:9661/native/custom-session')).assertEqual('unsafeEndpoint');
      expect(await errorFor('custom-session', undefined, 'Bearer wrong-account-token')).assertEqual('authenticationRequired');
      expect(await errorFor('custom-session', 'missing')).assertEqual('accountNotFound');
    });
    it('native_account_does_not_forward_credentials_across_origins', 0, async () => {
      expect(await errorFor('redirect')).assertEqual('redirectRejected');
      expect(await errorFor('cross-origin-session')).assertEqual('untrustedApiOrigin');
    });
    it('native_account_limits_streaming_body_and_checks_content_type', 0, async () => {
      expect(await errorFor('oversized')).assertEqual('responseTooLarge');
      expect(await errorFor('html')).assertEqual('invalidResponse');
    });
    it('native_account_correlates_replies_and_does_not_replay_posts', 0, async () => {
      expect(await errorFor('mismatch-session', 'z_selected')).assertEqual('invalidResponse');
      expect(await errorFor('post-redirect-session', 'z_selected')).assertEqual('redirectRejected');
    });
  });
}
