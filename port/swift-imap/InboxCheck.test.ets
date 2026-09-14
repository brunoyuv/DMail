// Isolated loopback-only metadata fixture. No real accounts or mail are read.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { NativeImapClient } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

class PollCredentials implements JmapCredentials {
  private mode: string;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(this.mode + ':fixture-password'));
  }
}
function core(mode: string): NativeImapClient { return new NativeImapClient('imaps://localhost:9761', new PollCredentials(mode)); }
function encoded(value: string): string {
  return new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(value))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
}
function cursor(next: number, validity: number = 77): string { return encoded(JSON.stringify({ version: 1, validity: validity, next: next })); }
interface Cursor { version: number; validity: number; next: number; }
function decoded(state: string): Cursor {
  const base = state.replace(/-/g, '+').replace(/_/g, '/');
  return JSON.parse(new util.TextDecoder().decodeToString(new util.Base64Helper().decodeSync(
    base + '='.repeat((4 - base.length % 4) % 4)))) as Cursor;
}
async function reject(client: NativeImapClient, state: string, expected: string): Promise<void> {
  let code = '';
  try { await client.checkInbox('default', state); } catch (error) { code = (error as JmapError).code; }
  expect(code).assertEqual(expected);
}
export default function tests(): void {
  describe('InboxCheck', () => {
    it('polls_only_bounded_uid_flags_and_keeps_baselines_and_later_arrivals_silent', 0, async () => {
      const client = core('poll-basic');
      const baseline = await client.checkInbox('default');
      expect(baseline.newMessages).assertEqual(0); expect(decoded(baseline.state).next).assertEqual(181);
      expect(baseline.unreadEmails).assertEqual(61);
      expect(baseline.mailboxId).assertEqual(encoded(JSON.stringify('INBOX')));
      expect((await client.checkInbox('default', baseline.state)).newMessages).assertEqual(0);
      expect((await client.checkInbox('default', cursor(170, 76))).newMessages).assertEqual(0);
      expect((await client.checkInbox('default', cursor(182))).newMessages).assertEqual(0);
      const empty = await core('poll-empty').checkInbox('default', cursor(170));
      expect(empty.newMessages).assertEqual(0); expect(empty.unreadEmails).assertEqual(0);
      for (const mode of ['poll-basic', 'poll-no-next']) {
        const changed = await core(mode).checkInbox('default', cursor(170));
        expect(changed.newMessages).assertEqual(5);
        expect(changed.unreadEmails).assertEqual(62);
        // The second EXAMINE reports UIDNEXT182: retain181 so it is checked later.
        expect(decoded(changed.state).next).assertEqual(181);
      }
      for (const mode of ['poll-count-rejected', 'poll-count-missing', 'poll-count-invalid', 'poll-count-drop']) {
        const changed = await core(mode).checkInbox('default', cursor(170));
        expect(changed.newMessages).assertEqual(5);
        expect(changed.unreadEmails === undefined).assertTrue();
        expect(decoded(changed.state).next).assertEqual(181);
      }
      const countStarted = Date.now();
      const stalled = await core('poll-count-stall').checkInbox('default', cursor(170));
      expect(stalled.newMessages).assertEqual(5);
      expect(stalled.unreadEmails === undefined).assertTrue();
      expect(decoded(stalled.state).next).assertEqual(181);
      expect(Date.now() - countStarted < 6000).assertTrue();
      await reject(core('poll-epoch'), cursor(170), 'queryChanged');
      // These requests must fail before opening any connection.
      for (const state of ['!', '', encoded('{"version":2,"validity":77,"next":181}'), encoded('{"version":1,"validity":0,"next":181}')]) {
        await reject(client, state, 'invalidArgument');
      }
    });
  });
}
