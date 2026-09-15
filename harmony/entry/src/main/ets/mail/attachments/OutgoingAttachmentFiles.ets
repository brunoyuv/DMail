// MPL-2.0: https://mozilla.org/MPL/2.0/
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { AttachmentFiles } from './AttachmentFiles';
import { OutgoingAttachment, SmtpAttachmentData, OUTGOING_ATTACHMENT_BYTES, outgoingAccountValid,
  outgoingUUIDValid, outgoingAttachmentReference, outgoingAttachmentsOwned, outgoingAttachmentType } from './OutgoingAttachmentModel';

const CHUNK_BYTES: number = 256 * 1024;
const WEEK_MS: number = 7 * 24 * 60 * 60 * 1000;

// The system picker grants access only for the explicit import. Persist an
// immutable app-private copy, so a saved draft never depends on that grant or
// on a document being moved/edited in another application. Database rows keep
// only account/draft-owned references; file bytes are read once for sending.
export class OutgoingAttachmentFiles {
  private filesDir: string;
  private root: string;
  private static tails: Map<string, Promise<void>> = new Map();
  private static retired: Set<string> = new Set();
  private static retiredDrafts: Set<string> = new Set();
  private static pruning: Set<string> = new Set();
  constructor(filesDir: string) {
    if (!filesDir.startsWith('/') || filesDir.includes('\u0000') || filesDir.includes('\\') ||
      filesDir.split('/').some(part => part === '.' || part === '..')) { throw new Error('Invalid attachment directory'); }
    this.filesDir = filesDir.replace(/\/+/g, '/').replace(/\/+$/, '');
    if (!this.filesDir) { throw new Error('Invalid attachment directory'); }
    this.root = `${this.filesDir}/mail-outgoing`;
  }
  private folder(accountId: string): string {
    if (!outgoingAccountValid(accountId)) { throw new Error('Invalid attachment account'); }
    return `${this.root}/${accountId}`;
  }
  private requireActive(folder: string, draftId: string, active: () => boolean): void {
    if (OutgoingAttachmentFiles.retired.has(folder) || OutgoingAttachmentFiles.retiredDrafts.has(`${folder}/${draftId.toLowerCase()}`) || !active()) { throw new Error('Attachment import canceled'); }
  }
  private serial<T>(folder: string, operation: () => Promise<T>): Promise<T> {
    const before = OutgoingAttachmentFiles.tails.get(folder) ?? Promise.resolve();
    const work = before.then(operation), settled = work.then(() => {}, () => {});
    OutgoingAttachmentFiles.tails.set(folder, settled);
    settled.then(() => { if (OutgoingAttachmentFiles.tails.get(folder) === settled) { OutgoingAttachmentFiles.tails.delete(folder); } });
    return work;
  }
  private async directory(path: string, create: boolean): Promise<void> {
    if (create) { try { await fs.mkdir(path); } catch (_) { /* Verify an existing directory below. */ } }
    const stat = await fs.lstat(path);
    if (stat.isSymbolicLink() || !stat.isDirectory()) { throw new Error('Invalid attachment directory'); }
  }
  private async directories(folder: string, draftId: string, create: boolean): Promise<string> {
    if (!outgoingUUIDValid(draftId)) { throw new Error('Invalid attachment draft'); }
    await this.directory(this.filesDir, false); await this.directory(this.root, create);
    await this.directory(folder, create);
    const draft = `${folder}/${draftId.toLowerCase()}`; await this.directory(draft, create); return draft;
  }
  private async absent(path: string): Promise<void> {
    let exists = false;
    try { await fs.lstat(path); exists = true; }
    catch (error) { if ((error as BusinessError).code !== 13900002) { throw new Error('Attachment path could not be checked'); } }
    if (exists) { throw new Error('Attachment filename collision'); }
  }
  async importURI(accountId: string, draftId: string, uri: string, remainingBytes: number,
    active: () => boolean): Promise<OutgoingAttachment> {
    const folder = this.folder(accountId);
    if (!outgoingUUIDValid(draftId) || !uri.startsWith('file://') || uri.includes('\u0000') ||
      !Number.isSafeInteger(remainingBytes) || remainingBytes < 0 || remainingBytes > OUTGOING_ATTACHMENT_BYTES) {
      throw new Error('Invalid attachment selection');
    }
    this.requireActive(folder, draftId, active);
    return this.serial(folder, async (): Promise<OutgoingAttachment> => {
      this.requireActive(folder, draftId, active);
      const id = util.generateRandomUUID().toLowerCase(), file = outgoingAttachmentReference(accountId, draftId, id);
      const name = AttachmentFiles.filename(new fileUri.FileUri(uri).name);
      const path = `${this.root}/${file}`, temporary = `${path}.part`;
      let temporaryOwned = false, published = false;
      try {
        const input = await fs.open(uri, fs.OpenMode.READ_ONLY);
        let size = 0;
        try {
          const original = await fs.stat(input.fd);
          if (!original.isFile() || !Number.isSafeInteger(original.size) || original.size < 0 || original.size > remainingBytes) {
            throw new Error('Attachment exceeds limit');
          }
          size = original.size;
          await this.directories(folder, draftId, true); this.requireActive(folder, draftId, active);
          await this.absent(path); await this.absent(temporary); this.requireActive(folder, draftId, active);
          const output = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
          temporaryOwned = true;
          try {
            const chunk = new ArrayBuffer(Math.max(1, Math.min(CHUNK_BYTES, size)));
            let read = 0, attempts = 0;
            while (read < size) {
              this.requireActive(folder, draftId, active);
              if (++attempts > 4096) { throw new Error('Incomplete attachment import'); }
              const wanted = Math.min(chunk.byteLength, size - read), count = await fs.read(input.fd, chunk, { length: wanted });
              if (!Number.isSafeInteger(count) || count <= 0 || count > wanted) { throw new Error('Incomplete attachment import'); }
              let written = 0;
              while (written < count) {
                this.requireActive(folder, draftId, active);
                if (++attempts > 4096) { throw new Error('Incomplete attachment import'); }
                const bytes = chunk.slice(written, count), saved = await fs.write(output.fd, bytes);
                if (!Number.isSafeInteger(saved) || saved <= 0 || saved > bytes.byteLength) { throw new Error('Incomplete attachment import'); }
                written += saved;
              }
              read += count;
            }
            const extra = await fs.read(input.fd, new ArrayBuffer(1));
            const after = await fs.stat(input.fd);
            if (extra !== 0 || after.size !== original.size || after.mtime !== original.mtime || after.ctime !== original.ctime) {
              throw new Error('Selected attachment changed');
            }
            this.requireActive(folder, draftId, active); await fs.fsync(output.fd);
          } finally { await fs.close(output); }
        } finally { await fs.close(input); }
        this.requireActive(folder, draftId, active); await this.absent(path); this.requireActive(folder, draftId, active);
        await fs.rename(temporary, path); published = true;
        this.requireActive(folder, draftId, active);
        return { id, name, contentType: outgoingAttachmentType(name), size, file };
      } catch (_) {
        if (temporaryOwned) { try { await fs.unlink(temporary); } catch (_) {} }
        if (published) { try { await fs.unlink(path); } catch (_) {} }
        throw new Error('Attachment could not be imported');
      }
    });
  }
  async read(accountId: string, draftId: string, attachment: OutgoingAttachment): Promise<SmtpAttachmentData> {
    const folder = this.folder(accountId);
    if (!outgoingAttachmentsOwned(accountId, draftId, [attachment])) { throw new Error('Invalid attachment reference'); }
    const active = (): boolean => true; this.requireActive(folder, draftId, active);
    return this.serial(folder, async (): Promise<SmtpAttachmentData> => {
      this.requireActive(folder, draftId, active); await this.directories(folder, draftId, false);
      const path = `${this.root}/${attachment.file}`, stat = await fs.lstat(path);
      if (stat.isSymbolicLink() || !stat.isFile() || stat.size !== attachment.size) { throw new Error('Attachment unavailable'); }
      const input = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const original = await fs.stat(input.fd);
        if (!original.isFile() || original.ino !== stat.ino || original.size !== stat.size || original.mtime !== stat.mtime) {
          throw new Error('Attachment changed');
        }
        const bytes = new Uint8Array(attachment.size), chunk = new ArrayBuffer(Math.max(1, Math.min(CHUNK_BYTES, attachment.size)));
        let offset = 0, attempts = 0;
        while (offset < bytes.length) {
          this.requireActive(folder, draftId, active);
          if (++attempts > 4096) { throw new Error('Incomplete attachment read'); }
          const wanted = Math.min(chunk.byteLength, bytes.length - offset), count = await fs.read(input.fd, chunk, { length: wanted });
          if (!Number.isSafeInteger(count) || count <= 0 || count > wanted) { throw new Error('Incomplete attachment read'); }
          bytes.set(new Uint8Array(chunk, 0, count), offset); offset += count;
        }
        const after = await fs.stat(input.fd);
        if (after.size !== original.size || after.mtime !== original.mtime || after.ctime !== original.ctime) { throw new Error('Attachment changed'); }
        this.requireActive(folder, draftId, active);
        const base64 = await new util.Base64Helper().encodeToString(bytes);
        this.requireActive(folder, draftId, active);
        return { id: attachment.id, name: attachment.name, contentType: attachment.contentType, size: attachment.size, base64 };
      } finally { await fs.close(input); }
    });
  }
  async path(accountId: string, draftId: string, attachment: OutgoingAttachment): Promise<string> {
    const folder = this.folder(accountId);
    if (!outgoingAttachmentsOwned(accountId, draftId, [attachment])) { throw new Error('Invalid attachment reference'); }
    const active = (): boolean => true; this.requireActive(folder, draftId, active);
    return this.serial(folder, async (): Promise<string> => {
      this.requireActive(folder, draftId, active); await this.directories(folder, draftId, false);
      const path = `${this.root}/${attachment.file}`, stat = await fs.lstat(path);
      if (stat.isSymbolicLink() || !stat.isFile() || stat.size !== attachment.size) { throw new Error('Attachment unavailable'); }
      this.requireActive(folder, draftId, active); return path;
    });
  }
  // Only call after the draft metadata no longer references this file. Sent
  // copies deliberately keep their references; normal draft saves never prune.
  async remove(accountId: string, draftId: string, attachment: OutgoingAttachment): Promise<void> {
    const folder = this.folder(accountId);
    if (!outgoingAttachmentsOwned(accountId, draftId, [attachment])) { throw new Error('Invalid attachment reference'); }
    return this.serial(folder, async (): Promise<void> => {
      this.requireActive(folder, draftId, (): boolean => true);
      await this.directories(folder, draftId, false);
      const path = `${this.root}/${attachment.file}`;
      try { await fs.unlink(path); }
      catch (error) { if ((error as BusinessError).code !== 13900002) { throw new Error('Attachment could not be removed'); } }
    });
  }
  // Explicitly discarding a draft cancels queued imports before deleting only
  // that draft's files. The account and other drafts remain usable.
  async forgetDraft(accountId: string, draftId: string): Promise<void> {
    const folder = this.folder(accountId);
    if (!outgoingUUIDValid(draftId)) { throw new Error('Invalid attachment draft'); }
    const draft = `${folder}/${draftId.toLowerCase()}`; OutgoingAttachmentFiles.retiredDrafts.add(draft);
    return this.serial(folder, async (): Promise<void> => {
      if (!await fs.access(draft)) { return; }
      await this.directory(this.filesDir, false); await this.directory(this.root, false); await this.directory(folder, false);
      const stat = await fs.lstat(draft);
      if (stat.isSymbolicLink()) { await fs.unlink(draft); return; }
      if (!stat.isDirectory()) { throw new Error('Invalid attachment directory'); }
      await fs.rmdir(draft);
    });
  }
  // Startup supplies all live draft and fresh local-Sent owners from small
  // database metadata. Never age out those references or scan while reading.
  // A partial/invalid ownership list is unsafe, so malformed input skips prune.
  async prune(retainedDrafts: string[]): Promise<void> {
    if (OutgoingAttachmentFiles.pruning.has(this.root)) { return; }
    const retained: Set<string> = new Set();
    for (const reference of retainedDrafts) {
      const parts = reference.split('/');
      if (parts.length !== 2 || !outgoingAccountValid(parts[0]) || !outgoingUUIDValid(parts[1])) { return; }
      retained.add(`${parts[0]}/${parts[1].toLowerCase()}`);
    }
    OutgoingAttachmentFiles.pruning.add(this.root);
    try { await this.pruneOwned(retained); }
    finally { OutgoingAttachmentFiles.pruning.delete(this.root); }
  }
  private async pruneOwned(retained: Set<string>): Promise<void> {
    try { await this.directory(this.filesDir, false); await this.directory(this.root, false); }
    catch (_) { return; }
    const deadline = Date.now() + 1000;
    let remaining = 128;
    for (const accountId of await fs.listFile(this.root, { recursion: false, listNum: remaining })) {
      if (--remaining < 0 || Date.now() > deadline) { break; }
      if (!outgoingAccountValid(accountId)) { continue; }
      const folder = this.folder(accountId);
      if (OutgoingAttachmentFiles.tails.has(folder) || OutgoingAttachmentFiles.retired.has(folder)) { continue; }
      await this.serial(folder, async (): Promise<void> => {
        try {
          await this.directory(folder, false);
          if (remaining <= 0 || Date.now() > deadline || OutgoingAttachmentFiles.retired.has(folder)) { return; }
          for (const draftId of await fs.listFile(folder, { recursion: false, listNum: remaining })) {
            if (--remaining < 0 || Date.now() > deadline || OutgoingAttachmentFiles.retired.has(folder)) { break; }
            if (!outgoingUUIDValid(draftId) || draftId !== draftId.toLowerCase() || retained.has(`${accountId}/${draftId}`)) { continue; }
            const draft = `${folder}/${draftId}`;
            if (OutgoingAttachmentFiles.retiredDrafts.has(draft)) { continue; }
            await this.directory(draft, false);
            if (remaining <= 0 || Date.now() > deadline) { break; }
            for (const name of await fs.listFile(draft, { recursion: false, listNum: remaining })) {
              if (--remaining < 0 || Date.now() > deadline || OutgoingAttachmentFiles.retired.has(folder) ||
                OutgoingAttachmentFiles.retiredDrafts.has(draft)) { break; }
              const temporary = name.endsWith('.bin.part'), suffix = temporary ? '.bin.part' : '.bin';
              if (!name.endsWith(suffix) || !outgoingUUIDValid(name.slice(0, -suffix.length))) { continue; }
              const path = `${draft}/${name}`, stat = await fs.lstat(path);
              if (!stat.isFile() || stat.isSymbolicLink()) { continue; }
              const age = Date.now() - stat.mtime * 1000;
              if (OutgoingAttachmentFiles.retired.has(folder) || OutgoingAttachmentFiles.retiredDrafts.has(draft)) { break; }
              if (temporary || (Number.isFinite(age) && age >= WEEK_MS)) { await fs.unlink(path); }
            }
          }
        } catch (_) { /* An inaccessible/changed directory stays untouched. */ }
      });
    }
  }
  async forgetAccount(accountId: string): Promise<void> {
    const folder = this.folder(accountId); OutgoingAttachmentFiles.retired.add(folder);
    return this.serial(folder, async (): Promise<void> => {
      if (!await fs.access(folder)) { return; }
      await this.directory(this.filesDir, false); await this.directory(this.root, false);
      const stat = await fs.lstat(folder);
      if (stat.isSymbolicLink()) { await fs.unlink(folder); return; }
      if (!stat.isDirectory()) { throw new Error('Invalid attachment directory'); }
      await fs.rmdir(folder);
    });
  }
}
