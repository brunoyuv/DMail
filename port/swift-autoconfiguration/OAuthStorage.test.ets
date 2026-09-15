import { describe, it, expect } from '@ohos/hypium';
import { util } from '@kit.ArkTS';
import { asset } from '@kit.AssetStoreKit';
import { OAuthSecretBox } from '../../../main/ets/data/OAuthSecretBox';

function alias(): string { return `tb.oauth.test.${util.generateRandomUUID()}`; }
async function rejects(operation: () => Promise<string>): Promise<void> {
  let failed = false;
  try { await operation(); } catch (_) { failed = true; }
  expect(failed).assertTrue();
}
interface Envelope { version: number; iv: string; ciphertext: string; }

export default function tests(): void {
  describe('HarmonyOAuthSecretStorage', () => {
    it('large_token_set_round_trips_with_small_unlocked_only_asset_key', 0, async () => {
      const id = alias();
      const payload = JSON.stringify({ accessToken: 'a'.repeat(24000), refreshToken: 'b'.repeat(24000), username: 'separate-login' });
      try {
        const envelope = await OAuthSecretBox.create(id, payload);
        expect(envelope.includes('separate-login')).assertFalse();
        expect(await OAuthSecretBox.open(id, envelope)).assertEqual(payload);
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(id));
        query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
        const stored = (await asset.query(query))[0];
        const bytes = stored.get(asset.Tag.SECRET) as Uint8Array;
        try { expect(bytes.length).assertEqual(32); }
        finally { bytes.fill(0); }
        expect(stored.get(asset.Tag.ACCESSIBILITY)).assertEqual(asset.Accessibility.DEVICE_UNLOCKED);
        expect(stored.get(asset.Tag.SYNC_TYPE)).assertEqual(asset.SyncType.NEVER);
      } finally { await OAuthSecretBox.remove(id); }
    });
    it('rotation_uses_new_nonce_and_duplicate_create_preserves_key', 0, async () => {
      const id = alias();
      try {
        const first = await OAuthSecretBox.create(id, 'old-refresh');
        await rejects(() => OAuthSecretBox.create(id, 'replacement-key'));
        expect(await OAuthSecretBox.open(id, first)).assertEqual('old-refresh');
        const second = await OAuthSecretBox.seal(id, 'rotated-refresh');
        expect((JSON.parse(first) as Envelope).iv === (JSON.parse(second) as Envelope).iv).assertFalse();
        expect(await OAuthSecretBox.open(id, second)).assertEqual('rotated-refresh');
      } finally { await OAuthSecretBox.remove(id); }
    });
    it('tampered_ciphertext_and_cross_account_envelope_are_rejected', 0, async () => {
      const firstId = alias(); const secondId = alias();
      try {
        const first = await OAuthSecretBox.create(firstId, 'private-token');
        await OAuthSecretBox.create(secondId, 'other-token');
        await rejects(() => OAuthSecretBox.open(secondId, first));
        const changed = JSON.parse(first) as Envelope;
        const base64 = new util.Base64Helper();
        const bytes = base64.decodeSync(changed.ciphertext); bytes[0] ^= 1;
        changed.ciphertext = base64.encodeToStringSync(bytes);
        await rejects(() => OAuthSecretBox.open(firstId, JSON.stringify(changed)));
        expect(await OAuthSecretBox.open(firstId, first)).assertEqual('private-token');
      } finally { await OAuthSecretBox.remove(firstId); await OAuthSecretBox.remove(secondId); }
    });
    it('removal_makes_ciphertext_unreadable_and_invalid_input_leaves_no_key', 0, async () => {
      const id = alias();
      try {
        await rejects(() => OAuthSecretBox.create(id, ''));
        const envelope = await OAuthSecretBox.create(id, 'synthetic-token');
        await rejects(() => OAuthSecretBox.seal(id, 'x'.repeat(131073)));
        await OAuthSecretBox.remove(id);
        await rejects(() => OAuthSecretBox.open(id, envelope));
        await OAuthSecretBox.remove(id);
      } finally { await OAuthSecretBox.remove(id); }
    });
  });
}
