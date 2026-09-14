// Actual Swift IDLE over local TLS, using only fabricated metadata.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { NativeImapClient, stopInboxWatch, ImapInboxWatch } from '../../../main/ets/mail/imap/NativeImapClient';
import { JmapCredentials, JmapError } from '../../../main/ets/mail/jmap/JmapClient';

class IdleCredentials implements JmapCredentials {
  private mode: string;
  calls: number = 0;
  constructor(mode: string) { this.mode = mode; }
  async authorization(): Promise<string> {
    this.calls++;
    return 'Basic ' + new util.Base64Helper().encodeToStringSync(new util.TextEncoder().encodeInto(this.mode + ':fixture-password'));
  }
}
function pause(ms: number): Promise<void> { return new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); }); }
async function until(client: NativeImapClient, id: string, unsupported: boolean = false): Promise<ImapInboxWatch> {
  for (let index = 0; index < 100; index++) {
    const value = await client.watchInbox(id);
    if (unsupported ? !value.supported : value.changed) { return value; }
    await pause(100);
  }
  throw new Error('Synthetic IDLE readiness/event deadline exceeded');
}
export default function tests(): void {
  describe('InboxWatch', () => {
    it('retains_one_idle_connection_for_ready_quiet_push_done_and_unsupported_fallback', 0, async () => {
      const id = util.generateRandomUUID(true), unsupportedId = util.generateRandomUUID(true), cancelId = util.generateRandomUUID(true);
      const credentials = new IdleCredentials('idle-watch');
      const client = new NativeImapClient('imaps://localhost:9761', credentials);
      try {
        expect((await until(client, id)).supported).assertTrue();
        for (let index = 0; index < 3; index++) {
          const quiet = await client.watchInbox(id);
          expect(quiet.supported).assertTrue(); expect(quiet.changed).assertFalse();
        }
        // A second identity cannot consume events or reuse the first connection.
        const other = new NativeImapClient('imaps://localhost:9765', new IdleCredentials('idle-unsupported'));
        let wrongOwner = '';
        try { await other.watchInbox(id); } catch (error) { wrongOwner = (error as JmapError).code; }
        expect(wrongOwner).assertEqual('invalidArgument');
        const trigger = new NativeImapClient('imaps://localhost:9761', new IdleCredentials('idle-trigger'));
        expect((await trigger.checkInbox('default')).newMessages).assertEqual(0);
        expect((await until(client, id)).changed).assertTrue();
        expect((await client.watchInbox(id)).changed).assertFalse();
        expect(credentials.calls).assertEqual(1);
        await stopInboxWatch(id);
        // The unsupported server never receives EXAMINE or IDLE.
        expect((await until(other, unsupportedId, true)).supported).assertFalse();
        await stopInboxWatch(unsupportedId);
        // Cancel while the selected-mailbox command is still waiting on its reply.
        const cancel = new NativeImapClient('imaps://localhost:9761', new IdleCredentials('idle-cancel'));
        await cancel.watchInbox(cancelId); await pause(500); await stopInboxWatch(cancelId);
        await pause(600);
      } finally {
        await stopInboxWatch(id); await stopInboxWatch(unsupportedId); await stopInboxWatch(cancelId);
      }
    });
  });
}
