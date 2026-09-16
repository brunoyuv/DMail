// MPL-2.0: https://mozilla.org/MPL/2.0/
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { htmlContentInset, preparedMailDocument, isEmbeddedMathFontRequest } from '../mail/html/HtmlDocument';
import { PreparedMailDocument } from '../data/PreparedDocumentModel';
import { PictureCache, CachedPicture, PictureSnapshotScope } from '../data/PictureCache';
import { loadPictureSnapshot, PictureSnapshotResource } from '../data/PictureSnapshot';

// Each mounted Web owns one document. Its finite picture attempt completes
// intercepted responses as bytes arrive, without replacing or rescanning HTML.
// Browser callbacks never read the database or start HTTP.
class HtmlReaderSnapshot {
  private static sequence: number = 0;
  static nextIdentity(): string { return `${Date.now().toString(36)}-${++HtmlReaderSnapshot.sequence}`; }
  id: string;
  url: string;
  html: string;
  pictures: Map<string, CachedPicture>;
  pictureIds: Map<string, string> = new Map();
  expected: Set<string> = new Set();
  settled: Set<string> = new Set();
  waiting: Map<string, WebResourceResponse[]> = new Map();
  waitingCount: number = 0;
  account: string = '';
  message: string = '';
  cache?: PictureCache;
  started: boolean = false;
  finished: boolean = false;
  cancelled: boolean = false;
  deadlineTimer: number = -1;
  controller: webview.WebviewController = new webview.WebviewController();
  attached: boolean = false;
  readonly embeddedMathFonts: boolean;
  constructor(id: string, html: string, pictures: Map<string, CachedPicture>) {
    this.id = id; this.url = `https://mail.invalid/snapshot/${id}/message.html`;
    this.html = html; this.pictures = pictures;
    this.embeddedMathFonts = html.slice(0, 512).includes("font-src data:;");
  }
}

@Component
export struct HtmlMail {
  @Prop @Watch('reload') html: string = '';
  @Prop @Watch('reload') messageKey: string = '';
  @Prop @Watch('reload') accountId: string = '';
  pictureCache?: PictureCache;
  savedDocument?: PreparedMailDocument;
  openLink?: (url: string) => Promise<void>;
  @Prop contentInset: number = 20;
  @Prop fitContent: boolean = false;
  @Prop @Watch('visibilityChanged') readerVisible: boolean = true;
  @StorageLink('mailPictureForeground') @Watch('foregroundChanged') private pictureForeground: boolean = true;
  @State private documents: HtmlReaderSnapshot[] = [];
  private active: boolean = false;
  private openingLink: boolean = false;
  private identityRevision: number = 0;
  private reloadQueued: boolean = false;
  private configuredAccount: string = '';
  private configuredMessage: string = '';
  private configuredCache?: PictureCache;
  private configured: boolean = false;

  private label(name: string): string {
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }

  aboutToAppear(): void {
    this.active = true; this.reload();
  }
  aboutToDisappear(): void {
    this.active = false; ++this.identityRevision;
    for (const snapshot of this.documents) { this.cancelSnapshot(snapshot); }
    this.documents = []; this.configured = false;
  }

  private foregroundChanged(): void {
    this.visibilityChanged();
  }

  private visibilityChanged(): void {
    for (const snapshot of this.documents) {
      const visible = this.active && this.readerVisible && this.pictureForeground;
      if (snapshot.attached) {
        try {
          if (visible) { snapshot.controller.onActive(); }
          else { snapshot.controller.onInactive(); }
        } catch (_) { /* The native view may already be detached. */ }
      }
      if (!visible && snapshot.started) { this.cancelSnapshot(snapshot); }
      else if (visible && !snapshot.started) { this.startPictures(snapshot); }
    }
  }

  private reload(): void {
    if (!this.active || this.reloadQueued) { return; }
    this.reloadQueued = true;
    // ArkUI may notify account, identity and body props separately within one
    // render. Capture their final values together before freezing the message.
    Promise.resolve().then(() => { this.reloadQueued = false; this.captureSnapshot(); });
  }

  private async captureSnapshot(): Promise<void> {
    if (!this.active) { return; }
    const sameIdentity = this.configured && this.configuredAccount === this.accountId &&
      this.configuredMessage === this.messageKey && this.configuredCache === this.pictureCache;
    // The explicit message loader owns preparation. Once opened, neither metadata,
    // theme or foreground updates can replace this reader's saved view.
    if (sameIdentity) { return; }
    ++this.identityRevision;
    const id = HtmlReaderSnapshot.nextIdentity();
    this.configured = true; this.configuredAccount = this.accountId;
    this.configuredMessage = this.messageKey; this.configuredCache = this.pictureCache;
    const account = this.accountId, message = this.messageKey, cache = this.pictureCache;
    const saved = this.savedDocument;
    // The fallback preserves already-cached legacy HTML as authored. This
    // wrapper only concatenates fixed CSS/CSP; it does not inspect the body.
    const document = saved?.html || preparedMailDocument(this.html, false, htmlContentInset(this.contentInset));
    for (const previous of this.documents) { this.cancelSnapshot(previous); }
    const pictures = new Map<string, CachedPicture>();
    const snapshot = new HtmlReaderSnapshot(id, document, pictures);
    snapshot.account = account; snapshot.message = message; snapshot.cache = cache;
    if (saved && cache && account && message && saved.pictures.length > 0) {
      for (const reference of saved.pictures) {
        snapshot.pictureIds.set(reference.url, reference.id); snapshot.expected.add(reference.id);
      }
    }
    // Publish the HTML before any picture-cache wait or network request.
    this.documents = [snapshot];
    this.startPictures(snapshot);
  }

  private currentSnapshot(snapshot: HtmlReaderSnapshot): boolean {
    return this.active && this.readerVisible && this.pictureForeground && !snapshot.cancelled &&
      this.documents.includes(snapshot) && snapshot.account === this.accountId && snapshot.message === this.messageKey && snapshot.cache === this.pictureCache;
  }

  private startPictures(snapshot: HtmlReaderSnapshot): void {
    if (snapshot.started || snapshot.finished || !this.currentSnapshot(snapshot)) { return; }
    snapshot.started = true;
    if (!snapshot.cache || snapshot.expected.size === 0) { this.finishPictures(snapshot); return; }
    const scope: PictureSnapshotScope = { active: () => this.currentSnapshot(snapshot), deadline: Date.now() + 30000 };
    // One deadline settles every pending browser response, even if an active
    // platform request outlives its download-start budget. This is not polling.
    snapshot.deadlineTimer = setTimeout(() => this.cancelSnapshot(snapshot), 30000);
    loadPictureSnapshot(snapshot.cache, snapshot.account, snapshot.message, Array.from(snapshot.pictureIds.keys()), false, scope,
      (resource: PictureSnapshotResource) => this.receivePicture(snapshot, resource)).then(result => {
      if (this.currentSnapshot(snapshot)) {
        for (const resource of result.resources) { this.receivePicture(snapshot, resource); }
      }
      this.finishPictures(snapshot);
    }, () => this.finishPictures(snapshot));
  }

  private receivePicture(snapshot: HtmlReaderSnapshot, resource: PictureSnapshotResource): void {
    if (!this.currentSnapshot(snapshot) || snapshot.finished) { return; }
    const id = snapshot.pictureIds.get(resource.url);
    if (!id || snapshot.settled.has(id)) { return; }
    snapshot.settled.add(id);
    if (resource.picture) { snapshot.pictures.set(id, resource.picture); }
    const waiting = snapshot.waiting.get(id) || [];
    snapshot.waiting.delete(id); snapshot.waitingCount -= waiting.length;
    for (const response of waiting) { this.completeResponse(response, resource.picture || undefined); }
  }

  private finishPictures(snapshot: HtmlReaderSnapshot): void {
    if (snapshot.finished) { return; }
    snapshot.finished = true;
    if (snapshot.deadlineTimer !== -1) { clearTimeout(snapshot.deadlineTimer); snapshot.deadlineTimer = -1; }
    for (const responses of snapshot.waiting.values()) {
      for (const response of responses) { this.completeResponse(response); }
    }
    snapshot.waiting.clear(); snapshot.waitingCount = 0;
  }

  private cancelSnapshot(snapshot: HtmlReaderSnapshot): void {
    if (!snapshot.finished && snapshot.started) { snapshot.cache?.cancelPending(snapshot.account, snapshot.message); }
    snapshot.cancelled = true;
    this.finishPictures(snapshot);
  }

  private completeResponse(response: WebResourceResponse, picture?: CachedPicture, document?: string): void {
    try {
      response.setResponseData(document !== undefined ? document : picture ? picture.data : '');
      response.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-store' }]);
      response.setResponseEncoding('UTF-8');
      response.setResponseMimeType(document !== undefined ? 'text/html' : picture ? picture.mimeType : 'text/plain');
      response.setResponseCode(document !== undefined || picture ? 200 : 403);
      response.setReasonMessage(document !== undefined || picture ? 'OK' : 'Blocked');
      response.setResponseIsReady(true);
    } catch (_) { /* A removed native view no longer consumes this response. */ }
  }

  private attachSnapshot(snapshot: HtmlReaderSnapshot): void {
    snapshot.attached = true;
    if (!this.readerVisible || !this.pictureForeground) {
      try { snapshot.controller.onInactive(); } catch (_) {}
    }
  }

  private document(snapshot: HtmlReaderSnapshot): string {
    return snapshot.html;
  }

  private resourceResponse(snapshot: HtmlReaderSnapshot, request: WebResourceRequest): WebResourceResponse {
    const url = request.getRequestUrl();
    const document = request.isMainFrame() && url === snapshot.url;
    const pictureUrl = url.split('#', 1)[0];
    const picture = request.isMainFrame() ? undefined : snapshot.pictures.get(pictureUrl);
    const response = new WebResourceResponse();
    if (!document && !picture && !request.isMainFrame() && snapshot.expected.has(pictureUrl) &&
      !snapshot.settled.has(pictureUrl) && !snapshot.finished && this.currentSnapshot(snapshot) && snapshot.waitingCount < 1024) {
      response.setResponseIsReady(false);
      const waiting = snapshot.waiting.get(pictureUrl) || [];
      waiting.push(response); snapshot.waiting.set(pictureUrl, waiting); snapshot.waitingCount++;
      return response;
    }
    this.completeResponse(response, picture, document ? this.document(snapshot) : undefined);
    return response;
  }

  private blockNavigation(snapshot: HtmlReaderSnapshot, request: WebResourceRequest): boolean {
    const target = request.getRequestUrl();
    if (target === snapshot.url || target.startsWith(snapshot.url + '#')) { return false; }
    if (this.active && this.readerVisible && this.pictureForeground && request.isMainFrame() && request.isRequestGesture() &&
      this.externalWebLink(target)) { this.launchLink(target); }
    return true;
  }

  private externalWebLink(url: string): boolean {
    return url.length <= 8192 && !/[\u0000-\u0020\u007f\\]/.test(url) &&
      /^https?:\/\/[^\s\\\/?#@]+(?:[\/?#]|$)/i.test(url) &&
      !/^https?:\/\/mail\.invalid(?::[0-9]+)?(?:[/?#]|$)/i.test(url);
  }

  private async launchLink(url: string): Promise<void> {
    if (this.openingLink) { return; }
    const revision = this.identityRevision;
    this.openingLink = true;
    try {
      if (this.openLink) { await this.openLink(url); }
      else { await (this.getUIContext().getHostContext() as common.UIAbilityContext).openLink(url); }
    } catch (_) {
      if (this.active && this.pictureForeground && revision === this.identityRevision) {
        this.getUIContext().getPromptAction().showToast({ message: this.label('link_open_error') });
      }
    } finally { this.openingLink = false; }
  }

  @Builder
  private content(snapshot: HtmlReaderSnapshot) {
    Web({ src: snapshot.url, controller: snapshot.controller, renderMode: RenderMode.SYNC_RENDER })
      .id('html-mail').width('100%').height('100%').layoutMode(this.fitContent ? WebLayoutMode.FIT_CONTENT : WebLayoutMode.NONE)
      .wideViewModeAccess(true).overviewModeAccess(true)
      .darkMode(WebDarkMode.Auto).forceDarkAccess(true).backgroundColor($r('app.color.mail_background'))
      .javaScriptAccess(false).blockNetwork(true).onlineImageAccess(true)
      .fileAccess(false).domStorageAccess(false).databaseAccess(false)
      .geolocationAccess(false).mixedMode(MixedMode.All).cacheMode(CacheMode.Online).multiWindowAccess(false)
      .onPermissionRequest((event) => event.request.deny()).onShowFileSelector(() => true)
      .onLoadIntercept((event) => this.blockNavigation(snapshot, event.data))
      .onInterceptRequest((event) => {
        const url = event.request.getRequestUrl();
        if (/^data:image\//i.test(url)) { return null; }
        if (isEmbeddedMathFontRequest(snapshot.embeddedMathFonts, url)) { return null; }
        return this.resourceResponse(snapshot, event.request);
      })
      .onControllerAttached(() => this.attachSnapshot(snapshot))
  }

  @Builder
  private savedContent() {
    ForEach(this.documents, (snapshot: HtmlReaderSnapshot) => { this.content(snapshot) }, (snapshot: HtmlReaderSnapshot) => snapshot.id)
  }

  build() {
    if (this.fitContent) {
      Column() {
        this.savedContent()
      }.width('100%')
    } else {
      Column() {
        Column() {
          this.savedContent()
        }.layoutWeight(1).width('100%')
      }.width('100%').height('100%')
    }
  }
}
