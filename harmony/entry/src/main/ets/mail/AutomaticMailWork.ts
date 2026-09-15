// MPL-2.0: https://mozilla.org/MPL/2.0/
export class AutomaticMailWorkCancelled extends Error {
  constructor() { super('Automatic mail work cancelled'); this.name = 'AutomaticMailWorkCancelled'; }
}
interface AutomaticMailOperation {
  active: () => boolean;
  execute: () => Promise<void>;
  cancel: () => void;
}

// One process-local lane for automatic checks/header requests. Callers keep
// their existing durable leases and deadlines; no work is created by this lane.
// Explicit user reads/sends do not enter it. Never nest run() within run().
export class AutomaticMailWork {
  private static pending: AutomaticMailOperation[] = [];
  private static running: boolean = false;
  private static timer: number = -1;
  private static finishedAt: number | null = null;
  private static readonly spacing: number = 3000;

  static run<T>(operation: () => Promise<T>, active: () => boolean = (): boolean => true): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const job: AutomaticMailOperation = { active,
        cancel: (): void => reject(new AutomaticMailWorkCancelled()),
        execute: async (): Promise<void> => {
          try { resolve(await operation()); } catch (error) { reject(error); }
        } };
      if (!AutomaticMailWork.isActive(job)) { job.cancel(); return; }
      AutomaticMailWork.pending.push(job); AutomaticMailWork.drain();
    });
  }

  // Lifecycle owners can retire obsolete waiting work immediately. The timer
  // otherwise checks ownership before starting; there is no cancellation poll.
  static cancelInactive(): void {
    const retained: AutomaticMailOperation[] = [];
    for (const job of AutomaticMailWork.pending) {
      if (AutomaticMailWork.isActive(job)) { retained.push(job); } else { job.cancel(); }
    }
    AutomaticMailWork.pending = retained;
    if (retained.length === 0 && AutomaticMailWork.timer !== -1) {
      clearTimeout(AutomaticMailWork.timer); AutomaticMailWork.timer = -1;
    }
  }

  private static isActive(job: AutomaticMailOperation): boolean {
    try { return job.active(); } catch (_) { return false; }
  }
  private static drain(): void {
    AutomaticMailWork.cancelInactive();
    if (AutomaticMailWork.running || AutomaticMailWork.timer !== -1 || AutomaticMailWork.pending.length === 0) { return; }
    const remaining = AutomaticMailWork.finishedAt === null ? 0 : Math.max(0,
      Math.min(AutomaticMailWork.spacing, AutomaticMailWork.finishedAt + AutomaticMailWork.spacing - Date.now()));
    if (remaining > 0) {
      AutomaticMailWork.timer = setTimeout(() => {
        AutomaticMailWork.timer = -1; AutomaticMailWork.finishedAt = null;
        AutomaticMailWork.drain();
      }, remaining);
      return;
    }
    const job = AutomaticMailWork.pending.shift()!;
    AutomaticMailWork.running = true;
    job.execute().finally(() => {
      AutomaticMailWork.finishedAt = Date.now(); AutomaticMailWork.running = false;
      AutomaticMailWork.drain();
    });
  }
}
