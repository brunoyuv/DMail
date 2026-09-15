import { describe, it, expect } from '@ohos/hypium';
import { request } from 'libimaptest.so';
import accountTests from './AccountCore.test';
export default function imapTests(): void {
  accountTests();
  describe('OriginalThunderbirdIMAP', () => {
    for (const mode of ['reader', 'bad', 'untrusted', 'wronghost', 'stall', 'drop', 'cancel', 'oversized', 'wrongtag']) {
      it(`native_imap_${mode}`, 0, async () => {
        const result = await request(mode);
        console.info(`IMAP_RESULT ${mode} ${result}`);
        expect(result).assertEqual(0);
      });
    }
    it('original_account_body_fixtures', 0, async () => { expect(await request('bodies')).assertEqual(0); });
  });
}
