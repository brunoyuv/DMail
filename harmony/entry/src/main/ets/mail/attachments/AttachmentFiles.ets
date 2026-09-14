// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common, wantConstant } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { MailAttachment, MailAttachmentData } from '../jmap/JmapClient';
import { cacheIsFresh } from '../../data/MailCacheModel';

export class AttachmentFiles {
  static readonly limit: number = 4 * 1024 * 1024;
  static filename(name: string): string {
    return name.replace(/[\\/\u0000-\u001f\u007f]/g, '_').replace(/^\.+/, '').slice(0, 100) || 'attachment';
  }
  static async prune(cacheDir: string): Promise<void> {
    const root = `${cacheDir}/mail-attachments`;
    if (!fs.accessSync(root)) { return; }
    for (const account of fs.listFileSync(root)) {
      const folder = `${root}/${account}`;
      if (!fs.statSync(folder).isDirectory()) { continue; }
      for (const name of fs.listFileSync(folder)) {
        const path = `${folder}/${name}`;
        if (fs.statSync(path).isFile() && (!cacheIsFresh(fs.statSync(path).mtime * 1000) || name.endsWith('.part'))) { fs.unlinkSync(path); }
      }
    }
  }
  static forgetAccount(cacheDir: string, accountId: string): void {
    if (!/^[A-Za-z0-9_-]+$/.test(accountId)) { return; }
    const folder = `${cacheDir}/mail-attachments/${accountId}`;
    if (fs.accessSync(folder)) { fs.rmdirSync(folder); }
  }
  static async load(context: common.UIAbilityContext, accountId: string, emailId: string, attachment: MailAttachment,
    download: () => Promise<MailAttachmentData>): Promise<string> {
    if (!/^[A-Za-z0-9_-]+$/.test(accountId)) { throw new Error('Invalid attachment account'); }
    await AttachmentFiles.prune(context.cacheDir);
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(`${emailId}\n${attachment.id}`) });
    const key = Array.from((await md.digest()).data).map((byte: number) => byte.toString(16).padStart(2, '0')).join('');
    const folder = `${context.cacheDir}/mail-attachments/${accountId}`;
    if (!fs.accessSync(folder)) { fs.mkdirSync(folder, true); }
    const path = `${folder}/${key}-${AttachmentFiles.filename(attachment.name)}`;
    if (fs.accessSync(path) && cacheIsFresh(fs.statSync(path).mtime * 1000)) { return path; }
    const response = await download();
    if (response.base64.length > 6 * 1024 * 1024) { throw new Error('Attachment exceeds limit'); }
    const bytes = new util.Base64Helper().decodeSync(response.base64);
    if (bytes.length > AttachmentFiles.limit) { throw new Error('Attachment exceeds limit'); }
    const temporary = `${path}.part`;
    try {
      const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try { fs.writeSync(file.fd, bytes.buffer); } finally { fs.closeSync(file); }
      fs.renameSync(temporary, path);
    } catch (error) {
      if (fs.accessSync(temporary)) { fs.unlinkSync(temporary); }
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
    const destination = fs.openSync(locations[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try { fs.copyFileSync(path, destination.fd); } finally { fs.closeSync(destination); }
  }
}
