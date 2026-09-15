// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common, wantConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { MailAttachment, MailAttachmentData } from '../jmap/JmapClient';
import { cacheIsFresh } from '../../data/MailCacheModel';

export class AttachmentFiles {
  static readonly limit: number = 4 * 1024 * 1024;
  private static pending: Map<string, Promise<string>> = new Map();
  private static cleaning: Map<string, Promise<void>> = new Map();
  private static revisions: Map<string, number> = new Map();
  private static retired: Set<string> = new Set();
  static filename(name: string): string {
    const clean = name.replace(/[\\/\u0000-\u001f\u007f]/g, '_').replace(/^\.+/, '') || 'attachment';
    // Leave room for the 64-byte cache key, separator and temporary .part.
    // Bound UTF-8 bytes without splitting a surrogate pair or losing .pdf.
    const extension = clean.match(/\.[a-z0-9]{1,12}$/i)?.[0] ?? '';
    const stem = extension ? clean.slice(0, -extension.length) : clean;
    let result = '', bytes = 0;
    for (let index = 0; index < stem.length; index++) {
      const code = stem.codePointAt(index) ?? 0;
      const width = code > 0xffff ? 2 : 1;
      const count = code <= 0x7f ? 1 : code <= 0x7ff ? 2 : width === 2 ? 4 : 3;
      if (bytes + count > 180 - extension.length || result.length + width > 100 - extension.length) { break; }
      result += code >= 0xd800 && code <= 0xdfff ? '_' : stem.slice(index, index + width);
      bytes += count; index += width - 1;
    }
    return result + extension || 'attachment';
  }
  static async prune(directory: string): Promise<void> {
    const root = `${directory}/mail-attachments`;
    if (!await fs.access(root)) { return; }
    for (const account of await fs.listFile(root)) {
      const folder = `${root}/${account}`;
      let names: string[];
      try {
        if (!(await fs.stat(folder)).isDirectory()) { continue; }
        names = await fs.listFile(folder);
      } catch (_) { continue; }
      for (const name of names) {
        const path = `${folder}/${name}`;
        const owner = name.endsWith('.part') ? path.slice(0, -5) : path;
        if (AttachmentFiles.pending.has(owner) || AttachmentFiles.cleaning.has(owner)) { continue; }
        const work = AttachmentFiles.pruneFile(path, owner);
        AttachmentFiles.cleaning.set(owner, work);
        try { await work; }
        finally { if (AttachmentFiles.cleaning.get(owner) === work) { AttachmentFiles.cleaning.delete(owner); } }
      }
    }
  }
  private static async pruneFile(path: string, owner: string): Promise<void> {
    try {
      const status = await fs.stat(path);
      if (!AttachmentFiles.pending.has(owner) && status.isFile() &&
        (!cacheIsFresh(status.mtime * 1000) || path.endsWith('.part'))) { await fs.unlink(path); }
    } catch (_) { /* A concurrent account removal may remove the file. */ }
  }
  static forgetAccount(directory: string, accountId: string): void {
    if (!/^[A-Za-z0-9_-]+$/.test(accountId)) { return; }
    const folder = `${directory}/mail-attachments/${accountId}`;
    AttachmentFiles.retired.add(folder);
    AttachmentFiles.revisions.set(folder, (AttachmentFiles.revisions.get(folder) ?? 0) + 1);
    if (fs.accessSync(folder)) { fs.rmdirSync(folder); }
  }
  static async load(context: common.UIAbilityContext, accountId: string, emailId: string, attachment: MailAttachment,
    download: () => Promise<MailAttachmentData>): Promise<string> {
    if (!/^[A-Za-z0-9_-]+$/.test(accountId)) { throw new Error('Invalid attachment account'); }
    const folder = `${context.filesDir}/mail-attachments/${accountId}`;
    const legacyFolder = `${context.cacheDir}/mail-attachments/${accountId}`;
    const revision = AttachmentFiles.revisions.get(folder) ?? 0;
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(`${emailId}\n${attachment.id}`) });
    const key = Array.from((await md.digest()).data).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
    const filename = `${key}-${AttachmentFiles.filename(attachment.name)}`;
    const path = `${folder}/${filename}`, legacy = `${legacyFolder}/${filename}`;
    AttachmentFiles.requireCurrent(folder, revision);
    const pending = AttachmentFiles.pending.get(path);
    if (pending) { return pending; }
    const work = AttachmentFiles.loadFile(folder, path, legacy, revision, download);
    AttachmentFiles.pending.set(path, work);
    // Legacy pruning must not remove the source while it is being migrated.
    AttachmentFiles.pending.set(legacy, work);
    try { return await work; }
    finally {
      if (AttachmentFiles.pending.get(path) === work) { AttachmentFiles.pending.delete(path); }
      if (AttachmentFiles.pending.get(legacy) === work) { AttachmentFiles.pending.delete(legacy); }
    }
  }
  private static requireCurrent(folder: string, revision: number): void {
    if (AttachmentFiles.retired.has(folder) || (AttachmentFiles.revisions.get(folder) ?? 0) !== revision) {
      throw new Error('Attachment account was removed');
    }
  }
  private static async fresh(path: string): Promise<boolean> {
    try {
      const status = await fs.stat(path);
      return status.isFile() && status.size >= 0 && status.size <= AttachmentFiles.limit && cacheIsFresh(status.mtime * 1000);
    } catch (_) { return false; }
  }
  private static async loadFile(folder: string, path: string, legacy: string, revision: number,
    download: () => Promise<MailAttachmentData>): Promise<string> {
    // An orphan unlink may already be in the native I/O queue. Finish it before
    // creating this path's new temporary file, even if pruning started first.
    const cleanup = AttachmentFiles.cleaning.get(path);
    if (cleanup) { await cleanup; }
    const legacyCleanup = AttachmentFiles.cleaning.get(legacy);
    if (legacyCleanup) { await legacyCleanup; }
    AttachmentFiles.requireCurrent(folder, revision);
    const fresh = await AttachmentFiles.fresh(path);
    AttachmentFiles.requireCurrent(folder, revision);
    if (fresh) { return path; }
    if (!await fs.access(folder)) {
      try { await fs.mkdir(folder, true); }
      catch (error) { if (!await fs.access(folder)) { throw error as Error; } }
    }
    AttachmentFiles.requireCurrent(folder, revision);
    // Move a completed old cache file rather than decoding/copying it again.
    // rename preserves its original download mtime, so upgrading cannot extend
    // retention. If migration is unavailable, the good legacy file still opens.
    if (legacy !== path && await AttachmentFiles.fresh(legacy)) {
      AttachmentFiles.requireCurrent(folder, revision);
      try { await fs.rename(legacy, path); }
      catch (_) {
        AttachmentFiles.requireCurrent(folder, revision);
        const available = await AttachmentFiles.fresh(legacy);
        AttachmentFiles.requireCurrent(folder, revision);
        if (available) { return legacy; }
        throw new Error('Attachment file could not be migrated');
      }
      AttachmentFiles.requireCurrent(folder, revision);
      return path;
    }
    AttachmentFiles.requireCurrent(folder, revision);
    const response = await download();
    AttachmentFiles.requireCurrent(folder, revision);
    if (response.base64.length > 6 * 1024 * 1024) { throw new Error('Attachment exceeds limit'); }
    const bytes = await new util.Base64Helper().decode(response.base64);
    if (bytes.length > AttachmentFiles.limit) { throw new Error('Attachment exceeds limit'); }
    const temporary = `${path}.part`;
    try {
      AttachmentFiles.requireCurrent(folder, revision);
      const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        let written = 0;
        let attempts = 0;
        while (written < bytes.length) {
          AttachmentFiles.requireCurrent(folder, revision);
          if (++attempts > 128) { throw new Error('Incomplete attachment write'); }
          const remaining = written === 0 && bytes.byteOffset === 0 && bytes.length === bytes.buffer.byteLength ?
            bytes.buffer : bytes.buffer.slice(bytes.byteOffset + written, bytes.byteOffset + bytes.length);
          const count = await fs.write(file.fd, remaining);
          if (!Number.isSafeInteger(count) || count <= 0 || count > bytes.length - written) {
            throw new Error('Incomplete attachment write');
          }
          written += count;
        }
      } finally { await fs.close(file); }
      AttachmentFiles.requireCurrent(folder, revision);
      await fs.rename(temporary, path);
      AttachmentFiles.requireCurrent(folder, revision);
    } catch (error) {
      try { if (await fs.access(temporary)) { await fs.unlink(temporary); } } catch (_) { /* Best effort cleanup. */ }
      throw new Error('Attachment file could not be written');
    }
    return path;
  }
  static async open(context: common.UIAbilityContext, path: string, contentType: string): Promise<void> {
    await context.startAbility({ action: 'ohos.want.action.viewData', uri: fileUri.getUriFromPath(path),
      type: /^[a-z0-9.+-]+\/[a-z0-9.+-]+$/i.test(contentType) ? contentType : 'application/octet-stream',
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION });
  }
  static async save(context: common.UIAbilityContext, path: string, name: string): Promise<void> {
    const locations = await new picker.DocumentViewPicker(context).save({ newFileNames: [AttachmentFiles.filename(name)] });
    if (locations.length === 0) { return; }
    const destination = await fs.open(locations[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { await fs.copyFile(path, destination.fd); } finally { await fs.close(destination); }
  }
}
