// Fixed stage names only; this helper is included solely in isolated test HAPs.
export class PictureRefreshTrace {
  private static stages: string[] = [];
  static reset(): void { PictureRefreshTrace.stages = []; }
  static record(stage: string): void {
    if (PictureRefreshTrace.stages.length < 120) { PictureRefreshTrace.stages.push(stage); }
  }
  static read(): string { return PictureRefreshTrace.stages.join(','); }
}
