// Test-only counters; imported only into the isolated staged HAP.
export class InboxIdleTrace {
  private static active: boolean = false;
  private static queries: number = 0;
  private static scans: number = 0;
  private static batches: number = 0;
  private static inboxShown: number = 0;
  private static inboxHidden: number = 0;
  private static completed: Set<string> = new Set();
  static start(): void {
    InboxIdleTrace.queries = 0; InboxIdleTrace.scans = 0; InboxIdleTrace.batches = 0;
    InboxIdleTrace.inboxShown = 0; InboxIdleTrace.inboxHidden = 0;
    InboxIdleTrace.completed.clear(); InboxIdleTrace.active = true;
  }
  static stop(): void { InboxIdleTrace.active = false; }
  static recordQuery(): void { if (InboxIdleTrace.active) { ++InboxIdleTrace.queries; } }
  static recordScan(): void { if (InboxIdleTrace.active) { ++InboxIdleTrace.scans; } }
  static recordBatch(): void { if (InboxIdleTrace.active) { ++InboxIdleTrace.batches; } }
  static recordInboxVisibility(visible: boolean): void {
    if (!InboxIdleTrace.active) { return; }
    if (visible) { ++InboxIdleTrace.inboxShown; } else { ++InboxIdleTrace.inboxHidden; }
  }
  static visibilityCounts(): string { return `${InboxIdleTrace.inboxShown},${InboxIdleTrace.inboxHidden}`; }
  static recordComplete(emailId: string): void {
    if (InboxIdleTrace.active) { InboxIdleTrace.completed.add(emailId); }
  }
  static completedCount(): number { return InboxIdleTrace.completed.size; }
  static counts(): string {
    return `${InboxIdleTrace.queries},${InboxIdleTrace.scans},${InboxIdleTrace.batches},${InboxIdleTrace.completed.size}`;
  }
}
