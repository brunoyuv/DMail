// Test-only leaf counters. No imports: production modules may instrument their
// entry points without pulling the synthetic worker/store fixture into startup.
export class StaticPictureTrace {
  private static active: boolean = false;
  private static scans: number = 0;
  private static batches: number = 0;

  static start(): void {
    StaticPictureTrace.scans = 0; StaticPictureTrace.batches = 0;
    StaticPictureTrace.active = true;
  }
  static stop(): void { StaticPictureTrace.active = false; }
  static recordScan(): void { if (StaticPictureTrace.active) { ++StaticPictureTrace.scans; } }
  static recordBatch(): void { if (StaticPictureTrace.active) { ++StaticPictureTrace.batches; } }
  static counts(): string { return `${StaticPictureTrace.scans},${StaticPictureTrace.batches}`; }
}
