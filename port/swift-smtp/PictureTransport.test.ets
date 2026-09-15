// Exercise actual NetworkKit redirects/binary bodies and actual PictureCache.
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { display } from '@kit.ArkUI';
import { Driver } from '@ohos.UiTest';
import EntryAbility from '../../../main/ets/abilities/EntryAbility';
import { PictureTransportFixture } from '../../../main/ets/support/PictureTransportFixture';

function same(actual: ArrayBuffer | Uint8Array, expected: Uint8Array): boolean {
  const bytes = actual instanceof ArrayBuffer ? new Uint8Array(actual) : actual;
  return bytes.length === expected.length && bytes.every((value, index) => value === expected[index]);
}

export default function tests(): void {
  describe('PictureTransport', () => {
    it('redirects_binary_formats_and_failed_refresh_use_original_account_cache', 0, async () => {
      const driver = Driver.create(); await driver.wakeUpDisplay();
      const screen = display.getDefaultDisplaySync();
      await driver.swipe(Math.round(screen.width / 2), Math.round(screen.height * 0.8),
        Math.round(screen.width / 2), Math.round(screen.height * 0.2), 600);
      await driver.delayMs(1000);
      const delegator = abilityDelegatorRegistry.getAbilityDelegator();
      const monitor: abilityDelegatorRegistry.AbilityMonitor = { abilityName: 'EntryAbility' };
      await delegator.addAbilityMonitor(monitor);
      await delegator.startAbility({ bundleName: 'org.thunderbird.harmony.imaptest', moduleName: 'entry', abilityName: 'EntryAbility' });
      const ability = await delegator.waitAbilityMonitor(monitor, 5000) as EntryAbility;
      expect(ability.context.applicationInfo.name).assertEqual('org.thunderbird.harmony.imaptest');
      const fixture = new PictureTransportFixture();
      try {
        // The monitor can resolve before the asynchronous startup page has
        // loaded. Establish a live window before the short HTTP-only test can
        // reach terminateSelf while its startup stage is still being prepared.
        await ability.hideNavigationFixture();
        await fixture.open(ability.context);
        const routes: string[] = ['/redirect-lower', '/redirect-upper', '/jpeg', '/gif', '/webp', '/png', '/mislabeled'];
        for (const route of routes) {
          const extension = route.startsWith('/redirect-') || route === '/mislabeled' ? 'png' : route.slice(1);
          const loaded = await fixture.load(route);
          await delegator.print(`PICTURE_TRANSPORT_STAGE: ${route.slice(1)} loaded=${loaded !== null}\n`);
          expect(loaded !== null).assertTrue();
          if (!loaded) { throw new Error('Synthetic image transport failed'); }
          expect(loaded.mimeType).assertEqual(`image/${extension}`);
          expect(same(loaded.data, fixture.expected(extension))).assertTrue();
          const cached = await fixture.saved(route);
          expect(cached !== null).assertTrue();
          if (!cached) { throw new Error('Synthetic image persistence failed'); }
          expect(cached.mime).assertEqual(`image/${extension}`);
          expect(same(cached.bytes, fixture.expected(extension))).assertTrue();
          const count = fixture.requests.length;
          expect((await fixture.load(route)) !== null).assertTrue();
          expect(fixture.requests.length).assertEqual(count);
        }
        // Current policy intentionally rejects explicit textual MIME, even when
        // the payload happens to start with valid image bytes. Diagnose, don't widen.
        expect(await fixture.load('/plain')).assertEqual(null);
        expect(await fixture.saved('/plain')).assertEqual(null);
        await delegator.print('PICTURE_TRANSPORT_STAGE: valid PNG with text/plain rejected as current policy\n');
        const original = await fixture.saved('/png'); expect(original !== null).assertTrue();
        fixture.invalid = true;
        const retained = await fixture.load('/png', true); expect(retained !== null).assertTrue();
        if (!retained || !original) { throw new Error('Synthetic cache missing'); }
        expect(same(retained.data, original.bytes)).assertTrue();
        const after = await fixture.saved('/png'); expect(after?.savedAt).assertEqual(original.savedAt);
        expect(after?.mime).assertEqual('image/png');
        expect(fixture.requests.length).assertEqual(11);
      } finally {
        await delegator.print(`PICTURE_TRANSPORT_REQUESTS: ${fixture.requests.join(',')}\n`);
        try {
          await fixture.close(stage => delegator.print(`PICTURE_TRANSPORT_CLEANUP: ${stage}\n`));
        } finally {
          try {
            await delegator.print('PICTURE_TRANSPORT_CLEANUP: ability_terminate_start\n');
            await ability.context.terminateSelf();
            await delegator.print('PICTURE_TRANSPORT_CLEANUP: ability_terminate_done\n');
          } finally {
            await delegator.print('PICTURE_TRANSPORT_CLEANUP: monitor_remove_start\n');
            await delegator.removeAbilityMonitor(monitor);
            await delegator.print('PICTURE_TRANSPORT_CLEANUP: monitor_remove_done\n');
          }
        }
      }
      await delegator.print('PICTURE_TRANSPORT_RESULT: two redirect/header-case chains and PNG JPEG GIF WebP persisted; wrong image subtype canonicalized; cache rereads made no requests; text/plain PNG rejected; invalid refresh retained bytes and timestamp; cleanup completed\n');
    });
  });
}
