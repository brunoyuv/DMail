// MPL-2.0: https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { JmapClient, JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';
import { HarmonyJmapTransport } from '../../../main/ets/mail/jmap/HarmonyJmapTransport';
class Credentials implements JmapCredentials {
  async authorization(): Promise<string> { return 'Bearer fixture-write-token'; }
}
const account = 'write_account';
function client(scenario: string): JmapClient {
  return new JmapClient('https://localhost:9661/writes/' + scenario + '/session', new HarmonyJmapTransport(), new Credentials());
}
async function setError(scenario: string): Promise<string> {
  try { await client(scenario).setKeyword(account, 'message', '$flagged', true); }
  catch (error) { return (error as JmapError).code; }
  return 'NO_ERROR';
}
export default function writeCoreTests(): void {
  describe('NativeMessageChanges', () => {
    it('native_keywords_patch_explicit_values_and_preserve_other_fields', 0, async () => {
      const writer = client('flags');
      expect(await writer.setKeyword(account, 'message', '$seen', true)).assertEqual('v1');
      expect(await writer.setKeyword(account, 'message', '$seen', false)).assertEqual('v2');
      expect(await writer.setKeyword(account, 'message', '$flagged', true)).assertEqual('v3');
      expect(await writer.setKeyword(account, 'message', '$flagged', false)).assertEqual('v4');
      const mail = await writer.readEmail(account, 'message');
      expect(mail?.keywords.join(',')).assertEqual('$custom');
      expect(mail?.mailboxIds.join(',')).assertEqual('inbox,label');
    });
    it('native_archive_undo_preserves_labels_keywords_and_existing_archive', 0, async () => {
      for (const scenario of ['archive', 'already']) {
        const writer = client(scenario);
        const undo = await writer.archiveEmail(account, 'message');
        expect(undo.addedArchive).assertEqual(scenario === 'archive');
        expect(undo.expectedMailboxIds.join(',')).assertEqual('archive,label');
        await writer.undoArchive(undo);
        const mail = await writer.readEmail(account, 'message');
        expect(mail?.mailboxIds.join(',')).assertEqual(scenario === 'archive' ? 'inbox,label' : 'archive,inbox,label');
        expect(mail?.keywords.includes('$custom')).assertTrue();
        if (scenario === 'archive') { expect(mail?.keywords.includes('$other')).assertTrue(); }
      }
    });
    it('native_changes_reject_stale_undo_and_racing_updates', 0, async () => {
      const writer = client('stale');
      const undo = await writer.archiveEmail(account, 'message');
      let code = 'NO_ERROR';
      try { await writer.undoArchive(undo); } catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('stateMismatch');
      expect(await setError('race')).assertEqual('stateMismatch');
    });
    it('native_changes_enforce_account_mailbox_and_request_limits', 0, async () => {
      expect(await setError('readonly')).assertEqual('accountReadOnly');
      expect(await setError('denied')).assertEqual('forbidden');
      expect(await setError('limit')).assertEqual('requestTooLarge');
      let code = 'NO_ERROR';
      try { await client('archiveDenied').archiveEmail(account, 'message'); }
      catch (error) { code = (error as JmapError).code; }
      expect(code).assertEqual('archiveUnavailable');
    });
    it('native_changes_validate_method_and_per_message_acknowledgements', 0, async () => {
      expect(await setError('forbidden')).assertEqual('forbidden');
      expect(await setError('notFound')).assertEqual('messageNotFound');
      expect(await setError('unknown')).assertEqual('updateRejected');
      expect(await setError('methodReadonly')).assertEqual('accountReadOnly');
      expect(await setError('conflicting')).assertEqual('invalidResponse');
      expect(await setError('badValue')).assertEqual('invalidResponse');
    });
    it('native_changes_do_not_replay_when_the_acknowledgement_is_lost', 0, async () => {
      expect(await setError('lost')).assertEqual('network');
      expect((await client('lost').readEmail(account, 'message'))?.keywords.includes('$flagged')).assertTrue();
    });
  });
}
