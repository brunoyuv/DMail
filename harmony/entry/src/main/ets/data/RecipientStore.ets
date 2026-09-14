// MPL-2.0: https://mozilla.org/MPL/2.0/
import { relationalStore } from '@kit.ArkData';
import { RecipientRecord, mergeRecipients } from './RecipientHistory';

// Small address history shares the encrypted account database. It is separate
// from seven-day message retention and is removed with its owning account.
export class RecipientStore {
  private db: relationalStore.RdbStore;
  private queue: (operation: () => Promise<void>) => Promise<void>;
  constructor(db: relationalStore.RdbStore, queue: (operation: () => Promise<void>) => Promise<void>) {
    this.db = db; this.queue = queue;
  }

  static async initialize(db: relationalStore.RdbStore): Promise<void> {
    await db.executeSql('CREATE TABLE IF NOT EXISTS recipient_history (account_id TEXT NOT NULL, email_key TEXT NOT NULL, email TEXT NOT NULL, name TEXT NOT NULL, last_used INTEGER NOT NULL, PRIMARY KEY (account_id, email_key))');
  }

  async list(accountId: string): Promise<RecipientRecord[]> {
    let result: RecipientRecord[] = [];
    await this.queue(async () => { result = await this.read(accountId); });
    return result;
  }

  private async read(accountId: string): Promise<RecipientRecord[]> {
    const rows = await this.db.querySql("SELECT r.email, r.name, r.last_used FROM recipient_history r JOIN accounts a ON a.id = r.account_id WHERE r.account_id = ? AND a.status = 'ready' ORDER BY r.last_used DESC, r.email", [accountId]);
    const result: RecipientRecord[] = [];
    try {
      while (rows.goToNextRow()) { result.push({ email: rows.getString(0), name: rows.getString(1), lastUsed: rows.getLong(2) }); }
    } finally { rows.close(); }
    return result;
  }

  remember(accountId: string, added: RecipientRecord[]): Promise<void> {
    if (added.length === 0) { return Promise.resolve(); }
    return this.queue(async () => {
      const previous = await this.read(accountId), next = mergeRecipients(previous, added);
      if (JSON.stringify(previous) === JSON.stringify(next)) { return; }
      this.db.beginTransaction();
      try {
        await this.db.executeSql('DELETE FROM recipient_history WHERE account_id = ?', [accountId]);
        for (const record of next) {
          await this.db.executeSql("INSERT INTO recipient_history (account_id, email_key, email, name, last_used) SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM accounts WHERE id = ? AND status = 'ready')",
            [accountId, record.email.toLowerCase(), record.email, record.name, record.lastUsed, accountId]);
        }
        this.db.commit();
      } catch (error) { this.db.rollBack(); throw error as Error; }
    });
  }
}
