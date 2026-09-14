// MPL-2.0: https://mozilla.org/MPL/2.0/
import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

interface Envelope { version: number; iv: string; ciphertext: string; }

export class OAuthSecretSession {
  private alias: string;
  private key?: cryptoFramework.SymKey;
  constructor(alias: string, key: cryptoFramework.SymKey) { this.alias = alias; this.key = key; }
  async open(envelope: string): Promise<string> {
    if (!this.key) { throw new Error('Credential session is closed'); }
    return OAuthSecretBox.decrypt(this.alias, envelope, this.key);
  }
  async seal(plaintext: string): Promise<string> {
    if (!this.key) { throw new Error('Credential session is closed'); }
    return OAuthSecretBox.encrypt(this.alias, plaintext, this.key);
  }
  close(): void { this.key?.clearMem(); this.key = undefined; }
}

// Asset Store secrets are limited to 1024 bytes. Store a per-account 256-bit
// key there; the account database receives only authenticated ciphertext. The
// caller owns the pending/ready/deleting row lifecycle across the two stores.
export class OAuthSecretBox {
  private static query(alias: string): asset.AssetMap {
    if (!/^[A-Za-z0-9._-]{1,180}$/.test(alias)) { throw new Error('Invalid credential alias'); }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, new util.TextEncoder().encodeInto(alias));
    return query;
  }

  static async create(alias: string, plaintext: string): Promise<string> {
    const query = OAuthSecretBox.query(alias);
    const key = await cryptoFramework.createSymKeyGenerator('AES256').generateSymKey();
    const bytes = key.getEncoded().data;
    try {
      // Validate/encrypt before creating the key so invalid input leaves no asset.
      const envelope = await OAuthSecretBox.encrypt(alias, plaintext, key);
      query.set(asset.Tag.SECRET, bytes);
      query.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      query.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      // Default uninstall behavior removes the key. Never overwrite an existing
      // key: a failed duplicate create must not make the saved account unreadable.
      await asset.add(query);
      return envelope;
    } catch (_) { throw new Error('Credential storage unavailable'); }
    finally { bytes.fill(0); key.clearMem(); }
  }

  private static async key(alias: string): Promise<cryptoFramework.SymKey> {
    const query = OAuthSecretBox.query(alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results = await asset.query(query);
      const bytes = results[0]?.get(asset.Tag.SECRET) as Uint8Array;
      if (!bytes) { throw new Error(); }
      try {
        if (bytes.length !== 32) { throw new Error(); }
        return await cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: bytes });
      } finally { bytes.fill(0); }
    } catch (_) { throw new Error('Credential storage unavailable'); }
  }

  private static aad(alias: string): cryptoFramework.DataBlob {
    return { data: new util.TextEncoder().encodeInto(`thunderbird.oauth.v1:${alias}`) };
  }

  static async encrypt(alias: string, plaintext: string, key: cryptoFramework.SymKey): Promise<string> {
    const bytes = plaintext === '' ? new Uint8Array(0) : new util.TextEncoder().encodeInto(plaintext);
    try {
      if (bytes.length < 1 || bytes.length > 131072) { throw new Error(); }
      const iv = await cryptoFramework.createRandom().generateRandom(12);
      const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: iv,
        aad: OAuthSecretBox.aad(alias), authTag: { data: new Uint8Array(16) } };
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
      // HarmonyOS appends the 16-byte authentication tag to the encrypted output.
      const encrypted = await cipher.doFinal({ data: bytes });
      if (!encrypted || encrypted.data.length !== bytes.length + 16) { throw new Error(); }
      const base64 = new util.Base64Helper();
      const envelope: Envelope = { version: 1, iv: base64.encodeToStringSync(iv.data),
        ciphertext: base64.encodeToStringSync(encrypted.data) };
      return JSON.stringify(envelope);
    } finally { bytes.fill(0); }
  }

  static async retain(alias: string, background: boolean = false): Promise<OAuthSecretSession> {
    // Both aliases contain the same key. Keep the original alias as the AAD so
    // a background token rotation remains readable by the foreground app.
    return new OAuthSecretSession(alias, await OAuthSecretBox.key(background ? `${alias}.background` : alias));
  }

  static async seal(alias: string, plaintext: string, background: boolean = false): Promise<string> {
    const session = await OAuthSecretBox.retain(alias, background);
    try { return await session.seal(plaintext); }
    catch (_) { throw new Error('Credential storage unavailable'); }
    finally { session.close(); }
  }

  static async open(alias: string, envelope: string, background: boolean = false): Promise<string> {
    const session = await OAuthSecretBox.retain(alias, background);
    try { return await session.open(envelope); }
    finally { session.close(); }
  }

  static async decrypt(alias: string, envelope: string, key: cryptoFramework.SymKey): Promise<string> {
    try {
      if (envelope.length > 180000) { throw new Error(); }
      const value = JSON.parse(envelope) as Envelope;
      if (value.version !== 1 || typeof value.iv !== 'string' || typeof value.ciphertext !== 'string') { throw new Error(); }
      const base64 = new util.Base64Helper();
      const iv = base64.decodeSync(value.iv);
      const encrypted = base64.decodeSync(value.ciphertext);
      if (iv.length !== 12 || encrypted.length < 17 || encrypted.length > 131088) { throw new Error(); }
      const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: iv },
        aad: OAuthSecretBox.aad(alias), authTag: { data: encrypted.slice(-16) } };
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
      const plaintext = await cipher.doFinal({ data: encrypted.slice(0, -16) });
      if (!plaintext) { throw new Error(); }
      try { return new util.TextDecoder('utf-8', { fatal: true }).decodeToString(plaintext.data); }
      finally { plaintext.data.fill(0); }
    } catch (_) { throw new Error('Credential storage unavailable'); }
  }

  static async remove(alias: string): Promise<void> {
    try { await asset.remove(OAuthSecretBox.query(alias)); }
    catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw new Error('Credential removal failed'); }
    }
  }
}
