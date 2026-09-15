// MPL-2.0: https://mozilla.org/MPL/2.0/

// Rest between actual backlog items. An empty or backed-off queue has no timer.
// The thermal API uses 0=COOL, 1=NORMAL/getting warm, 2+=WARM or hotter.
export function mailSyncRestMs(workMs: number, thermalLevel: number): number {
  const elapsed = Number.isFinite(workMs) ? Math.max(0, workMs) : 0;
  return thermalLevel >= 1 ? Math.min(10000, Math.max(1000, elapsed * 2)) :
    Math.min(5000, Math.max(250, elapsed));
}

export function mailSyncThermallyAllowed(level: number): boolean { return level < 2; }
