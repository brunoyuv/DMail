// Synthetic IMAP only. No production accounts or messages are accessed.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

class FlagCredentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(this.mode + ':fixture-password'));
  }
}
function core(mode: string): NativeImapClient {
  return new NativeImapClient('imaps://localhost:9761', new FlagCredentials(mode));
}
function messageId(): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(
    JSON.stringify({ mailbox: 'INBOX', uid: 42, validity: 77 }))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
async function rejects(mode: string, enabled: boolean, code: string): Promise<void> {
  let failed = false;
  try { await core(mode).setKeyword('default', messageId(), '$seen', enabled); }
  catch (error) { failed = true; expect((error as JmapError).code).assertEqual(code); }
  expect(failed).assertTrue();
}
export default function tests(): void {
  describe('UnreadCompatibility', () => {
    it('repeated_seen_toggles_ignore_unrelated_fetch_and_optional_uidnext', 0, async () => {
      for (const mode of ['flag-no-next', 'flag-no-next-after', 'flag-unsolicited', 'flag-compat']) {
        const client = core(mode);
        for (const enabled of [true, false, true, false]) {
          expect((await client.setKeyword('default', messageId(), '$seen', enabled)).length > 0).assertTrue();
        }
      }
    });
    it('incomplete_or_ambiguous_target_flags_never_claim_success', 0, async () => {
      await rejects('flag-missing-flags', false, 'changeUnconfirmed');
      for (const mode of ['flag-missing-target', 'flag-duplicate-target', 'flag-ignored']) {
        await rejects(mode, true, 'changeUnconfirmed');
      }
    });
    it('changed_uidvalidity_or_lost_store_reply_is_not_retried', 0, async () => {
      await rejects('flag-epoch-changed', true, 'changeUnconfirmed');
      await rejects('flag-lost', true, 'changeUnconfirmed');
    });
  });
}
