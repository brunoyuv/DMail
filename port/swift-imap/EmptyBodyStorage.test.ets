// MPL-2.0: https://mozilla.org/MPL/2.0/
// Isolated app-private fixtures only; no production account or provider access.
import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { MailContentFiles } from '../../../main/ets/data/MailContentFiles';

export default function emptyBodyStorageTests(): void {
  describe('EmptyBodyStorage', () => {
    it('native_unicode_body_files_reopen', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext();
      const files = new MailContentFiles(context.filesDir);
      const account = 'unicode_fixture_' + util.generateRandomUUID().replace(/-/g, '');
      try {
        const content = '标题🙂e\u0301\nSaved text';
        const reference = await files.write(account, 'text', content);
        expect(await new MailContentFiles(context.filesDir).read(account, reference, 100)).assertEqual(content);
        await delegator.print('EMPTY_BODY_STORAGE: unicode-complete\n');
      } finally { await files.forgetAccount(account); }
    });
    it('native_empty_body_files_reopen', 0, async () => {
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const context = delegator.getAppContext();
      const files = new MailContentFiles(context.filesDir);
      const account = 'empty_fixture_' + util.generateRandomUUID().replace(/-/g, '');
      try {
        await delegator.print('EMPTY_BODY_STORAGE: write-empty\n');
        const text = await files.write(account, 'text', '');
        const html = await files.write(account, 'html', '');
        await delegator.print('EMPTY_BODY_STORAGE: read-empty\n');
        const reopened = new MailContentFiles(context.filesDir);
        expect(await reopened.read(account, text, 0)).assertEqual('');
        expect(await reopened.read(account, html, 0)).assertEqual('');
        await delegator.print('EMPTY_BODY_STORAGE: files-complete\n');
      } finally { await files.forgetAccount(account); }
    });
  });
}
