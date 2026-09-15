// MPL-2.0: https://mozilla.org/MPL/2.0/
// Coalesce editing bursts without serializing a large draft for every key.
// Callers capture account ownership; explicit actions/lifecycle flush the queue.
export class DeferredSave {
  private static pending: Set<DeferredSave> = new Set();
  private timer: number = -1;
  private firstEdit: number = 0;
  private latest: (() => Promise<void>) | null = null;
  private running: Promise<void> | null = null;

  schedule(write: () => Promise<void>): void {
    if (!this.latest) { this.firstEdit = Date.now(); }
    this.latest = write; DeferredSave.pending.add(this);
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    // One pending edit replaces all intermediate snapshots behind a slow save.
    if (this.running) { return; }
    const delay = Math.max(0, Math.min(400, 2000 - (Date.now() - this.firstEdit)));
    this.timer = setTimeout(() => { this.timer = -1; this.start(false).catch(() => {}); }, delay);
  }

  cancel(): void {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    this.latest = null;
    if (!this.running) { DeferredSave.pending.delete(this); }
  }

  flush(): Promise<void> { return this.start(true); }

  private start(boundary: boolean): Promise<void> {
    if (this.timer !== -1) { clearTimeout(this.timer); this.timer = -1; }
    if (!this.latest) {
      if (!this.running) { DeferredSave.pending.delete(this); }
      return this.running || Promise.resolve();
    }
    if (this.running && !boundary) { return this.running; }
    const write = this.latest; this.latest = null;
    const previous = this.running;
    let failure: Error | null = null;
    let saved: Promise<void>;
    // At an explicit boundary, submit the captured account's final snapshot
    // now. AccountStore orders it before a following account switch/discard/send.
    try { saved = write().catch((error: Error) => { failure = error; }); }
    catch (error) { failure = error as Error; saved = Promise.resolve(); }
    const task = Promise.all([previous ? previous.catch(() => {}) : Promise.resolve(), saved])
      .then(() => { if (failure) { throw failure; } });
    this.running = task;
    task.then(() => this.finished(task), () => this.finished(task));
    return task;
  }

  private finished(task: Promise<void>): void {
    if (this.running !== task) { return; }
    this.running = null;
    if (this.latest) { this.start(false).catch(() => {}); }
    else { DeferredSave.pending.delete(this); }
  }

  static async flushAll(): Promise<void> {
    while (DeferredSave.pending.size > 0) {
      await Promise.all(Array.from(DeferredSave.pending).map(queue => queue.flush().catch(() => {})));
    }
  }
}
