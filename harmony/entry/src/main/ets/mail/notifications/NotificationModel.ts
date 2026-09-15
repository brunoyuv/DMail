// MPL-2.0: https://mozilla.org/MPL/2.0/
export const FOREGROUND_MINUTES: number[] = [5, 15, 30, 60];
export const BACKGROUND_MINUTES: number[] = [120, 240, 360, 720];
export class NotificationAccountState {
  accountId: string = '';
  enabled: boolean = false;
  revision: number = 0;
  notificationId: number = 0;
  foregroundMinutes: number = 5;
  backgroundMinutes: number = 120;
  cursor: string = '';
  mailboxId: string = '';
  lastAttempt: number = 0;
  lastCheck: number = 0;
  failures: number = 0;
  noticeVersion: number = 0;
  acknowledgedVersion: number = 0;
}
export interface InboxCheck { state: string; mailboxId: string; newMessages: number; unreadEmails?: number; }

export function validFrequencies(foreground: number, background: number): boolean {
  return FOREGROUND_MINUTES.includes(foreground) && BACKGROUND_MINUTES.includes(background);
}
export function nextCheckAt(value: NotificationAccountState, background: boolean, now: number): number {
  if (value.lastAttempt <= 0 || value.lastAttempt > now) { return now; }
  const minutes = background ? value.backgroundMinutes : value.foregroundMinutes;
  const backoff = Math.min(24 * 60, minutes * Math.pow(2, Math.min(5, value.failures)));
  return value.lastAttempt + backoff * 60000;
}
export function checkIsDue(value: NotificationAccountState, background: boolean, now: number): boolean {
  return value.enabled && now >= nextCheckAt(value, background, now);
}
export function scheduledMinutes(values: NotificationAccountState[]): number | null {
  const enabled = values.filter(value => value.enabled);
  return enabled.length === 0 ? null : Math.max(120, Math.min(...enabled.map(value => value.backgroundMinutes)));
}

// JMAP fallback compares bounded opaque identifiers, never a message's read flag
// alone. Initial enable and a changed Inbox identity establish a silent baseline.
interface JmapCheckpoint {
  version: number;
  mailboxId: string;
  ids: string[];
  latest: number;
  latestIds?: string[];
  latestComplete?: boolean;
  latestOverflow?: boolean;
}
export interface InboxSummary { id: string; receivedAt: number; unread: boolean; }
export function compareJmapInbox(cursor: string, mailboxId: string, messages: InboxSummary[],
  nextPosition?: number | null, notFound?: string[]): InboxCheck {
  let previous: JmapCheckpoint | null = null;
  if (cursor) {
    try {
      const decoded = JSON.parse(cursor) as JmapCheckpoint;
      if (decoded.version === 2 && decoded.mailboxId === mailboxId && Number.isFinite(decoded.latest) && decoded.latest >= 0 && Array.isArray(decoded.ids) &&
        decoded.ids.length <= 500 && decoded.ids.every(id => typeof id === 'string' && id.length <= 4096)) {
        const validLatestIds = Array.isArray(decoded.latestIds) && decoded.latestIds.length <= 500 &&
          decoded.latestIds.every(id => typeof id === 'string' && id.length <= 4096);
        decoded.latestComplete = validLatestIds && decoded.latestComplete === true && decoded.latestOverflow !== true;
        // Old version-2 cursors lack timestamp membership. Preserve their known
        // IDs conservatively until a newer timestamp starts a fresh group.
        if (!validLatestIds) { decoded.latestIds = decoded.ids; }
        previous = decoded;
      }
    } catch (_) {}
  }
  const known = new Set((previous?.ids || []).concat(previous?.latestIds || []));
  const newMessages = previous ? new Set(messages.filter(mail => mail.unread && !known.has(mail.id) &&
    Number.isFinite(mail.receivedAt) && (mail.receivedAt > previous!.latest ||
      (mail.receivedAt === previous!.latest && previous!.latestComplete === true))).map(mail => mail.id)).size : 0;
  const latest = Math.max(previous?.latest || 0, ...messages.map(mail => Number.isFinite(mail.receivedAt) ? Math.max(0, mail.receivedAt) : 0));
  const sameTimestamp = previous !== null && previous.latest === latest;
  const timestampIds = Array.from(new Set((sameTimestamp ? previous?.latestIds || [] : [])
    .concat(messages.filter(mail => mail.receivedAt === latest).map(mail => mail.id))));
  const latestOverflow = timestampIds.length > 500 || (sameTimestamp && previous?.latestOverflow === true);
  const latestIds = timestampIds.slice(0, 500), pinned = new Set(latestIds);
  // The original Swift query sorts receivedAt descending. Seeing an older row
  // or the end of the query proves that its newest timestamp group fit in this
  // page; missing Email/get rows cannot establish that proof.
  const pageComplete = nextPosition !== undefined && notFound !== undefined && notFound.length === 0 &&
    messages.every(mail => Number.isFinite(mail.receivedAt) && mail.receivedAt >= 0) &&
    (nextPosition === null || messages.some(mail => mail.receivedAt < latest));
  const latestComplete = !latestOverflow && (pageComplete || (sameTimestamp && previous?.latestComplete === true));
  // Pin timestamp peers even after they leave the page; otherwise a later page
  // shift could make an old peer look new. Keep both ID lists within 500 total.
  const retained = Array.from(new Set(messages.map(mail => mail.id).concat(previous?.ids || [])))
    .filter(id => !pinned.has(id)).slice(0, 500 - latestIds.length);
  const checkpoint: JmapCheckpoint = { version: 2, mailboxId, ids: retained, latest, latestIds, latestComplete, latestOverflow };
  return { state: JSON.stringify(checkpoint), mailboxId, newMessages };
}
