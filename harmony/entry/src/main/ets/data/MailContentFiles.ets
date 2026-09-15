// MPL-2.0: https://mozilla.org/MPL/2.0/
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { MailContentFileStore, MailContentKind, mailContentAccountValid, mailContentReferenceValid } from './MailContentFileModel';
export { MailContentFileStore, MailContentKind, mailContentReference, mailContentReferenceValid } from './MailContentFileModel';

const MAX_BYTES: number = 32 * 1024 * 1024;
const CHUNK_BYTES: number = 256 * 1024;
const WEEK_MS: number = 7 * 24 * 60 * 60 * 1000;
const TEMP_MS: number = 60 * 60 * 1000;

// Readable UTF-8 is intentionally confined to app-private persistent storage.
// References are generated immutable filenames; the database owns association
// with messages. Uncommitted files are harmless orphans removed by bounded prune.
export class MailContentFiles implements MailContentFileStore {
  private root: string;
  private filesDir: string;
  private static tails: Map<string, Promise<void>> = new Map();
  private static revisions: Map<string, number> = new Map();
  private static retired: Set<string> = new Set();
  private static pruning: Map<string, Promise<void>> = new Map();

  constructor(filesDir: string) {
    if (!filesDir.startsWith('/') || filesDir.includes('\u0000') || filesDir.includes('\\') ||
      filesDir.split('/').some(part => part === '.' || part === '..')) { throw new Error('Invalid mail content directory'); }
    this.filesDir = filesDir.replace(/\/+/g, '/').replace(/\/+$/, '');
    if (!this.filesDir) { throw new Error('Invalid mail content directory'); }
    this.root = `${this.filesDir}/mail-content`;
  }

  private folder(accountId: string): string {
    if (!mailContentAccountValid(accountId)) { throw new Error('Invalid mail content account'); }
    return `${this.root}/${accountId}`;
  }

  private current(folder: string, revision: number): void {
    if (MailContentFiles.retired.has(folder) || (MailContentFiles.revisions.get(folder) ?? 0) !== revision) {
      throw new Error('Mail content account was removed');
    }
  }

  private serial<T>(folder: string, operation: () => Promise<T>): Promise<T> {
    const before = MailContentFiles.tails.get(folder) || Promise.resolve();
    const work = before.then(operation);
    const settled = work.then(() => {}, () => {});
    MailContentFiles.tails.set(folder, settled);
    settled.then(() => { if (MailContentFiles.tails.get(folder) === settled) { MailContentFiles.tails.delete(folder); } });
    return work;
  }

  private async directory(path: string, create: boolean): Promise<void> {
    if (create) {
      try { await fs.mkdir(path); }
      catch (_) { /* An existing directory is checked without following links. */ }
    }
    const status = await fs.lstat(path);
    if (status.isSymbolicLink() || !status.isDirectory()) { throw new Error('Invalid mail content directory'); }
  }

  private async directories(folder: string, create: boolean): Promise<void> {
    await this.directory(this.filesDir, false);
    await this.directory(this.root, create);
    await this.directory(folder, create);
  }

  private async absent(path: string): Promise<void> {
    let present = false;
    try { await fs.lstat(path); present = true; }
    catch (error) {
      // access() can hide a dangling symbolic link; lstat must establish absence.
      const code = (error as BusinessError).code;
      if (code !== 13900002) { throw new Error('Mail content path could not be checked'); }
    }
    if (present) { throw new Error('Mail content filename collision'); }
  }

  private encode(content: string): Uint8Array {
    if (content.length > MAX_BYTES) { throw new Error('Mail content exceeds limit'); }
    let length = 0;
    for (let index = 0; index < content.length; index++) {
      const code = content.charCodeAt(index);
      if (code >= 0xd800 && code <= 0xdbff) {
        const next = content.charCodeAt(++index);
        if (!(next >= 0xdc00 && next <= 0xdfff)) { throw new Error('Invalid mail content Unicode'); }
        length += 4;
      } else if (code >= 0xdc00 && code <= 0xdfff) { throw new Error('Invalid mail content Unicode'); }
      else { length += code < 0x80 ? 1 : code < 0x800 ? 2 : 3; }
      if (length > MAX_BYTES) { throw new Error('Mail content exceeds limit'); }
    }
    return new util.TextEncoder().encodeInto(content);
  }

  async write(accountId: string, kind: MailContentKind, content: string): Promise<string> {
    const folder = this.folder(accountId), revision = MailContentFiles.revisions.get(folder) ?? 0;
    this.current(folder, revision);
    if (kind !== 'text' && kind !== 'html') { throw new Error('Invalid mail content kind'); }
    return this.serial(folder, async (): Promise<string> => {
      this.current(folder, revision);
      const bytes = this.encode(content);
      const reference = `${accountId}/${util.generateRandomUUID().toLowerCase()}.${kind === 'text' ? 'txt' : 'html'}`;
      if (!mailContentReferenceValid(accountId, reference, kind)) { throw new Error('Invalid generated mail reference'); }
      const path = `${this.root}/${reference}`, temporary = `${path}.part`;
      let owned = false, renamed = false;
      try {
        await this.directories(folder, true); this.current(folder, revision);
        await this.absent(path); await this.absent(temporary); this.current(folder, revision);
        const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
        owned = true;
        try {
          const initial = await fs.stat(file.fd);
          if (!initial.isFile() || initial.size !== 0) { throw new Error('Invalid temporary mail content'); }
          let written = 0, attempts = 0;
          while (written < bytes.length) {
            this.current(folder, revision);
            if (++attempts > 4096) { throw new Error('Incomplete mail content write'); }
            const chunk = bytes.buffer.slice(bytes.byteOffset + written, bytes.byteOffset + Math.min(bytes.length, written + CHUNK_BYTES));
            const count = await fs.write(file.fd, chunk);
            if (!Number.isSafeInteger(count) || count <= 0 || count > chunk.byteLength) { throw new Error('Incomplete mail content write'); }
            written += count;
          }
          await fs.fsync(file.fd);
        } finally { await fs.close(file); }
        this.current(folder, revision);
        await this.directories(folder, false); await this.absent(path); this.current(folder, revision);
        await fs.rename(temporary, path); renamed = true;
        this.current(folder, revision);
        return reference;
      } catch (_) {
        if (owned) {
          try { await fs.unlink(renamed ? path : temporary); } catch (_) { /* Account cleanup may already own it. */ }
        }
        throw new Error('Mail content could not be saved');
      }
    });
  }

  async read(accountId: string, reference: string, maxCharacters: number): Promise<string> {
    const folder = this.folder(accountId), revision = MailContentFiles.revisions.get(folder) ?? 0;
    if (!mailContentReferenceValid(accountId, reference) || !Number.isSafeInteger(maxCharacters) ||
      maxCharacters < 0 || maxCharacters > MAX_BYTES) { throw new Error('Invalid mail content reference'); }
    return this.serial(folder, async (): Promise<string> => {
      this.current(folder, revision);
      await this.directories(folder, false); this.current(folder, revision);
      const path = `${this.root}/${reference}`, status = await fs.lstat(path);
      if (status.isSymbolicLink() || !status.isFile()) { throw new Error('Invalid mail content file'); }
      const age = Date.now() - status.mtime * 1000;
      if (!Number.isFinite(age) || age < -60000 || age >= WEEK_MS || !Number.isSafeInteger(status.size) ||
        status.size < 0 || status.size > MAX_BYTES || status.size > maxCharacters * 3) { throw new Error('Mail content unavailable'); }
      const file = await fs.open(path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        const opened = await fs.stat(file.fd);
        if (!opened.isFile() || opened.ino !== status.ino || opened.size !== status.size || opened.mtime !== status.mtime) {
          throw new Error('Mail content changed');
        }
        const bytes = new Uint8Array(status.size), chunk = new Uint8Array(Math.min(CHUNK_BYTES, status.size));
        let offset = 0, attempts = 0;
        while (offset < bytes.length) {
          this.current(folder, revision);
          if (++attempts > 4096) { throw new Error('Incomplete mail content read'); }
          const wanted = Math.min(chunk.length, bytes.length - offset);
          const count = await fs.read(file.fd, chunk.buffer, { length: wanted });
          if (!Number.isSafeInteger(count) || count <= 0 || count > wanted) { throw new Error('Incomplete mail content read'); }
          bytes.set(chunk.subarray(0, count), offset); offset += count;
        }
        const after = await fs.stat(file.fd);
        if (after.size !== opened.size || after.mtime !== opened.mtime || after.ctime !== opened.ctime) { throw new Error('Mail content changed'); }
        this.current(folder, revision);
        const text = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
        if (text.length > maxCharacters) { throw new Error('Mail content exceeds limit'); }
        return text;
      } finally { await fs.close(file); }
    });
  }

  async forgetAccount(accountId: string): Promise<void> {
    const folder = this.folder(accountId);
    MailContentFiles.revisions.set(folder, (MailContentFiles.revisions.get(folder) ?? 0) + 1);
    MailContentFiles.retired.add(folder);
    await this.serial(folder, async (): Promise<void> => {
      try { await this.directory(this.filesDir, false); await this.directory(this.root, false); }
      catch (_) { return; }
      let status: fs.Stat;
      try { status = await fs.lstat(folder); } catch (_) { return; }
      if (status.isSymbolicLink()) { await fs.unlink(folder); return; }
      if (!status.isDirectory()) { throw new Error('Invalid mail content directory'); }
      // This store creates a flat directory. Never recursively traverse an
      // unexpected subdirectory or a symbolic link during account removal.
      for (const name of await fs.listFile(folder, { recursion: false })) {
        if (!name || name.includes('/') || name.includes('\\') || name === '.' || name === '..') { continue; }
        const path = `${folder}/${name}`, entry = await fs.lstat(path);
        if (!entry.isDirectory() || entry.isSymbolicLink()) { await fs.unlink(path); }
      }
      // Harmony rmdir is recursive, so use it only after confirming emptiness.
      if ((await fs.listFile(folder, { recursion: false, listNum: 1 })).length === 0) { await fs.rmdir(folder); }
    });
  }

  prune(): Promise<void> {
    const pending = MailContentFiles.pruning.get(this.root);
    if (pending) { return pending; }
    const work = this.pruneOwned(); MailContentFiles.pruning.set(this.root, work);
    work.then(() => { MailContentFiles.pruning.delete(this.root); }, () => { MailContentFiles.pruning.delete(this.root); });
    return work;
  }

  private async pruneOwned(): Promise<void> {
    try { await this.directory(this.filesDir, false); await this.directory(this.root, false); }
    catch (_) { return; }
    const deadline = Date.now() + 1000;
    let remaining = 512;
    for (const accountId of await fs.listFile(this.root, { recursion: false, listNum: 32 })) {
      if (remaining <= 0 || Date.now() > deadline) { break; }
      if (!mailContentAccountValid(accountId)) { continue; }
      const folder = this.folder(accountId);
      if (MailContentFiles.tails.has(folder) || MailContentFiles.retired.has(folder)) { continue; }
      await this.serial(folder, async (): Promise<void> => {
        try {
          await this.directories(folder, false);
          for (const name of await fs.listFile(folder, { recursion: false, listNum: Math.min(128, remaining) })) {
            if (--remaining < 0 || Date.now() > deadline) { break; }
            const temporary = name.endsWith('.part'), base = temporary ? name.slice(0, -5) : name;
            if (!mailContentReferenceValid(accountId, `${accountId}/${base}`)) { continue; }
            const path = `${folder}/${name}`, status = await fs.lstat(path);
            if (!status.isFile() || status.isSymbolicLink()) { continue; }
            const age = Date.now() - status.mtime * 1000;
            if (Number.isFinite(age) && age >= (temporary ? TEMP_MS : WEEK_MS)) { await fs.unlink(path); }
          }
        } catch (_) { /* Concurrent cleanup or inaccessible files stay untouched. */ }
      });
    }
  }
}
