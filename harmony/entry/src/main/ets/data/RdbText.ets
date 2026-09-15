// MPL-2.0: https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

// RDB's shared ResultSet window cannot return one row above 2 MiB, even
// though SQLite successfully stores it. Leave room for the scalar columns.
export const RDB_TEXT_INLINE_BYTES: number = 1024 * 1024;
const RDB_TEXT_CHUNK_BYTES: number = 256 * 1024;

export function rdbTextProjection(expression: string): string {
  return `CASE WHEN length(CAST((${expression}) AS BLOB)) <= ${RDB_TEXT_INLINE_BYTES} THEN (${expression}) ELSE '' END`;
}

// sql is application-authored and selects one column named payload, at most
// one row. Keep account/identity/metadata guards in that statement. Byte
// substrings avoid repeatedly scanning UTF-8 prefixes, and decode only after
// reassembly so a multibyte code point may safely cross any chunk boundary.
export async function readRdbText(db: relationalStore.RdbStore, sql: string,
  bindArgs: relationalStore.ValueType[], maxCharacters: number, expectedBytes?: number): Promise<string | null> {
  if (!Number.isSafeInteger(maxCharacters) || maxCharacters < 0 || maxCharacters > 64 * 1024 * 1024) {
    throw new Error('Invalid stored text limit');
  }
  let bytes: Uint8Array | null = null;
  let offset = 0;
  do {
    const rows = await db.querySql(`SELECT length(CAST(payload AS BLOB)),
      substr(CAST(payload AS BLOB), ?, ?) FROM (${sql}) rdb_text_source`,
      [offset + 1, RDB_TEXT_CHUNK_BYTES, ...bindArgs]);
    try {
      if (!rows.goToFirstRow()) {
        if (offset === 0 && expectedBytes === undefined) { return null; }
        throw new Error('Stored text changed');
      }
      const length = rows.getLong(0);
      // A UTF-16 code unit occupies at most three UTF-8 bytes. The exact
      // original character bound is checked after decoding as well.
      if (!Number.isSafeInteger(length) || length < 0 || length > maxCharacters * 3 ||
        (expectedBytes !== undefined && length !== expectedBytes)) { throw new Error('Invalid stored text size'); }
      if (bytes === null) { bytes = new Uint8Array(length); }
      if (length !== bytes.length) { throw new Error('Stored text changed'); }
      const chunk = length === 0 ? new Uint8Array() : rows.getBlob(1);
      if (chunk.length !== Math.min(RDB_TEXT_CHUNK_BYTES, length - offset)) { throw new Error('Incomplete stored text'); }
      bytes.set(chunk, offset); offset += chunk.length;
      if (rows.goToNextRow()) { throw new Error('Ambiguous stored text'); }
    } finally { rows.close(); }
  } while (bytes !== null && offset < bytes.length);
  if (bytes === null) { throw new Error('Incomplete stored text'); }
  const text = new util.TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes);
  if (text.length > maxCharacters) { throw new Error('Invalid stored text size'); }
  // Separate RDB queries can observe another handle's commits. Length alone
  // cannot detect same-size replacements. Never publish assembled bytes unless
  // they equal one complete, still-owned value in SQLite. This is a bounded
  // validation, not a retry loop or a new copy outside the encrypted database.
  const check = await db.querySql(`SELECT 1 FROM (${sql}) rdb_text_source WHERE payload = ?`, [...bindArgs, text]);
  try {
    if (!check.goToFirstRow() || check.goToNextRow()) { throw new Error('Stored text changed'); }
  } finally { check.close(); }
  return text;
}
