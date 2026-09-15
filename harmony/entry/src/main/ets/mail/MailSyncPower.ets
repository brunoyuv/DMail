// MPL-2.0: https://mozilla.org/MPL/2.0/
import { thermal } from '@kit.BasicServicesKit';

// One platform subscription shared by foreground and scheduled workers. This
// observes device heat; it neither changes OS limits nor polls an idle Inbox.
export class MailSyncPower {
  private static listeners: Set<() => void> = new Set();
  private static current: number = 0;
  private static subscribed: boolean = false;
  private static generation: number = 0;

  static level(): number { return MailSyncPower.current; }

  static subscribe(listener: () => void): () => void {
    if (MailSyncPower.listeners.size === 0) {
      const generation = ++MailSyncPower.generation;
      let observed = false;
      MailSyncPower.current = 0;
      try {
        thermal.registerThermalLevelCallback((level: thermal.ThermalLevel) => {
          if (generation !== MailSyncPower.generation || !MailSyncPower.valid(level)) { return; }
          observed = true;
          if (level === MailSyncPower.current) { return; }
          MailSyncPower.current = level;
          for (const callback of Array.from(MailSyncPower.listeners)) {
            if (MailSyncPower.listeners.has(callback)) { try { callback(); } catch (_) {} }
          }
        });
        MailSyncPower.subscribed = true;
      } catch (_) {
        // If the device lacks thermal callbacks, the ordinary pacing budget
        // still applies. Do not strand work behind an unobservable heat state.
        ++MailSyncPower.generation;
        try { thermal.unregisterThermalLevelCallback(); } catch (_) {}
        MailSyncPower.current = 0;
      }
      if (MailSyncPower.subscribed) {
        try {
          const initial = thermal.getLevel();
          if (!observed && MailSyncPower.valid(initial)) { MailSyncPower.current = initial; }
        } catch (_) {}
      }
    }
    // Each subscription owns one entry, even if callers reuse a callback.
    const entry = (): void => listener();
    MailSyncPower.listeners.add(entry);
    let closed = false;
    return (): void => {
      if (closed) { return; }
      closed = true;
      MailSyncPower.listeners.delete(entry);
      if (MailSyncPower.listeners.size > 0) { return; }
      ++MailSyncPower.generation;
      if (MailSyncPower.subscribed) {
        try { thermal.unregisterThermalLevelCallback(); } catch (_) {}
      }
      MailSyncPower.subscribed = false; MailSyncPower.current = 0;
    };
  }

  private static valid(level: number): boolean { return Number.isSafeInteger(level) && level >= 0 && level <= 7; }
}
