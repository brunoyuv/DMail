// MPL-2.0: https://mozilla.org/MPL/2.0/
import { PictureCache, PictureSnapshotWindow, PictureSnapshotScope, SnapshotPicture, MAX_SNAPSHOT_PICTURES, MAX_SNAPSHOT_BYTES } from './PictureCache';

export interface PictureSnapshotResource extends SnapshotPicture {}
export interface PictureSnapshotResult { resources: PictureSnapshotResource[]; saved: boolean; cancelled: boolean; }
export type PictureSnapshotObserver = (resource: PictureSnapshotResource) => void;
interface SnapshotFlight { window: PictureSnapshotWindow; task: Promise<PictureSnapshotResult>; urlsKey: string; retry: boolean; observer?: PictureSnapshotObserver; }

const flights: Map<PictureCache, Map<string, SnapshotFlight>> = new Map();
const ATTEMPT_MS = 30000;

// One finite attempt may supply resource bytes as they arrive. The final saved
// attempt still makes subsequent opens cache-only, including failed pictures.
export function loadPictureSnapshot(cache: PictureCache, accountId: string, messageKey: string,
  urls: string[], retry: boolean = false, scope?: PictureSnapshotScope, observer?: PictureSnapshotObserver): Promise<PictureSnapshotResult> {
  const key = JSON.stringify([accountId, messageKey]);
  const requested = Array.from(new Set(urls.slice(0, MAX_SNAPSHOT_PICTURES))).filter(url => url.length <= 8192);
  const urlsKey = JSON.stringify(requested);
  const owned = flights.get(cache) || new Map<string, SnapshotFlight>();
  const existing = owned.get(key);
  if (existing && existing.window.scope === scope && cache.snapshotCurrent(existing.window) && existing.urlsKey === urlsKey && existing.retry === retry && existing.observer === observer) { return existing.task; }
  const window = cache.snapshotWindow(accountId, messageKey, Date.now() + ATTEMPT_MS, scope);
  const load = (): Promise<PictureSnapshotResult> => {
    window.deadline = Math.min(Date.now() + ATTEMPT_MS, scope?.deadline ?? Number.POSITIVE_INFINITY);
    return prepareSnapshot(cache, accountId, messageKey, requested, retry, window, observer);
  };
  // A new reader waits for the cancelled predecessor's active requests. Its
  // successful bytes are reused, while superseded queued sockets stay cancelled.
  const task = existing ? existing.task.then(load, load) : load();
  const flight: SnapshotFlight = { window, task, urlsKey, retry, observer };
  owned.set(key, flight); flights.set(cache, owned);
  const tracked = task.then(() => {}, () => {});
  cache.trackSnapshot(tracked);
  const cleanup = (): void => {
    if (owned.get(key) === flight) { owned.delete(key); }
    if (owned.size === 0 && flights.get(cache) === owned) { flights.delete(cache); }
  };
  // Retire before callers awaiting this promise can issue a later explicit
  // retry. Deferring cleanup through another promise turn would join old failures.
  task.then(cleanup, cleanup);
  return task;
}

async function prepareSnapshot(cache: PictureCache, accountId: string, messageKey: string, requested: string[],
  retry: boolean, window: PictureSnapshotWindow, observer?: PictureSnapshotObserver): Promise<PictureSnapshotResult> {
  const urls = Array.from(new Set(requested.slice(0, MAX_SNAPSHOT_PICTURES))).filter(url => url.length <= 8192);
  let resources: PictureSnapshotResource[] = urls.map((url: string): PictureSnapshotResource => ({ url, picture: null, failure: 'storage', status: 0 }));
  const reported = new Set<string>();
  const notify = (resource: PictureSnapshotResource): void => {
    if (!observer || reported.has(resource.url) || !cache.snapshotCurrent(window)) { return; }
    reported.add(resource.url);
    try { observer({ url: resource.url, picture: resource.picture, failure: resource.failure, status: resource.status }); }
    catch (_) { /* A detached display must not fail or replay a cache download. */ }
  };
  try {
    // Permission is now automatic, but ready-account storage ownership remains
    // mandatory and is independently rechecked immediately before each socket.
    await cache.allow(accountId, messageKey);
    const snapshot = await cache.readSnapshot(accountId, messageKey, urls);
    resources = snapshot.resources;
    for (const resource of resources) { if (resource.picture || (snapshot.attempted && !retry)) { notify(resource); } }
    if (snapshot.attempted && !retry) { return { resources, saved: true, cancelled: !cache.snapshotCurrent(window) }; }
    if (!cache.snapshotCurrent(window)) { return { resources, saved: false, cancelled: true }; }
    let index = 0, bytes = resources.reduce((total, resource) => total + (resource.picture?.data.byteLength || 0), 0);
    const worker = async (): Promise<void> => {
      while (index < resources.length && cache.snapshotCurrent(window) && Date.now() < window.deadline) {
        const resource = resources[index++];
        if (resource.picture) { continue; }
        if (bytes >= MAX_SNAPSHOT_BYTES) { resource.failure = 'size'; notify(resource); continue; }
        const result = await cache.loadForSnapshot(accountId, messageKey, resource.url, window);
        resource.failure = result.failure || (result.picture ? '' : 'network'); resource.status = result.status;
        if (result.picture) {
          if (bytes + result.picture.data.byteLength <= MAX_SNAPSHOT_BYTES) {
            resource.picture = result.picture; bytes += result.picture.data.byteLength;
          } else { resource.failure = 'size'; }
        }
        notify(resource);
      }
    };
    await Promise.all([worker(), worker(), worker(), worker()]);
    if (!cache.snapshotCurrent(window)) { return { resources, saved: false, cancelled: true }; }
    const saved = await cache.saveSnapshot(accountId, messageKey, resources, window).catch(() => false);
    return { resources, saved, cancelled: !cache.snapshotCurrent(window) };
  } catch (_) {
    // A cache read failure must not be mistaken for an absent manifest and
    // silently restart downloads. Retain only fixed local failure categories.
    return { resources, saved: false, cancelled: !cache.snapshotCurrent(window) };
  }
}
