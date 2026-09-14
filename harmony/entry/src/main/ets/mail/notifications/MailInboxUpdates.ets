// MPL-2.0: https://mozilla.org/MPL/2.0/

// Process-local arrival hints. Retain each account's version so a busy view or
// an account switch cannot consume another inbox's update. Message data stays
// in the encrypted cache; this bus only asks the foreground UI to refresh it.
export class MailInboxUpdates {
  private static versions: Map<string, number> = new Map();
  private static foreground: boolean = false;
  static isForeground(): boolean { return MailInboxUpdates.foreground; }
  static setForeground(foreground: boolean): void {
    if (foreground === MailInboxUpdates.foreground) { return; }
    MailInboxUpdates.foreground = foreground;
    AppStorage.setOrCreate('mailInboxUpdateRevision', (AppStorage.get<number>('mailInboxUpdateRevision') || 0) + 1);
  }
  static revision(accountId: string): number { return MailInboxUpdates.versions.get(accountId) || 0; }
  static request(accountId: string): void {
    if (!accountId) { return; }
    MailInboxUpdates.versions.set(accountId, MailInboxUpdates.revision(accountId) + 1);
    AppStorage.setOrCreate('mailInboxUpdateRevision', (AppStorage.get<number>('mailInboxUpdateRevision') || 0) + 1);
  }
}
