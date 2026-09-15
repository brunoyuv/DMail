// MPL-2.0: https://mozilla.org/MPL/2.0/
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { FrameCallback } from '@kit.ArkUI';
import { hasRemotePictures, htmlContentInset, prepareMailHtml, preparedMailDocument } from '../mail/html/HtmlDocument';
import { PictureCache, PictureLoadResult } from '../data/PictureCache';

class HtmlRefreshFrame extends FrameCallback {
  private refresh: () => void;
  constructor(refresh: () => void) { super(); this.refresh = refresh; }
  onFrame(_frameTimeInNano: number): void { this.refresh(); }
}

@Component
export struct HtmlMail {
  @Prop @Watch('reload') html: string = '';
  @Prop @Watch('reload') messageKey: string = '';
  @Prop @Watch('reload') accountId: string = '';
  pictureCache?: PictureCache;
  openLink?: (url: string) => Promise<void>;
  @Prop @Watch('refreshDocument') contentInset: number = 20;
  @Prop fitContent: boolean = false;
  @StorageLink('appLanguageRevision') @Watch('refreshDocument') private languageRevision: number = 0;
  @StorageLink('mailPictureForeground') @Watch('foregroundChanged') private pictureForeground: boolean = true;
  @State private remoteImages: boolean = false;
  @State private checkingPictures: boolean = true;
  @State private savingPictures: boolean = false;
  @State private pictureSaveFailed: boolean = false;
  @State private pictureRequests: number = 0;
  @State private pictureRetryPending: boolean = false;
  @State private pictureFailureSummary: string = '';
  private pictureFailureReasons: Map<string, string> = new Map();
  private pictureLoadRevision: number = 0;
  private picturesHtml: string | null = null;
  private picturesPresent: boolean = false;
  private preparedSource: string | null = null;
  private preparedLanguage: number = -1;
  private preparedBody: string = '';
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private controller: webview.WebviewController = new webview.WebviewController();
  private attached: boolean = false;
  private refreshRevision: number = 0;
  private pendingDocumentRefresh: boolean = false;
  private identityRevision: number = 0;
  private configuredRevision: number = -1;
  private configuredHtml: string | null = null;
  private configuredAccount: string = '';
  private configuredMessage: string = '';
  private configuredCache?: PictureCache;
  private active: boolean = false;
  private openingLink: boolean = false;
  private pictureOwnerCache?: PictureCache;
  private pictureOwnerAccount: string = '';
  private pictureOwnerMessage: string = '';
  private readonly initialDocumentUrl: string = 'https://mail.invalid/message.html';
  private documentUrl: string = this.initialDocumentUrl;

  aboutToAppear(): void { this.active = true; this.reload(); }
  aboutToDisappear(): void {
    this.active = false; this.attached = false; ++this.refreshRevision; ++this.identityRevision;
    this.releasePictures();
    this.preparedSource = null; this.preparedBody = ''; this.configuredHtml = null; this.configuredCache = undefined;
  }
  private releasePictures(): void {
    if (this.pictureOwnerAccount && this.pictureOwnerMessage) {
      this.pictureOwnerCache?.cancelPending(this.pictureOwnerAccount, this.pictureOwnerMessage);
    }
    this.pictureOwnerCache = undefined; this.pictureOwnerAccount = ''; this.pictureOwnerMessage = '';
  }
  private foregroundChanged(): void {
    if (!this.pictureForeground) {
      // Remember only unfinished work. A fully rendered offline copy needs
      // neither a new document nor another consent read on every resume.
      this.pendingDocumentRefresh = this.pendingDocumentRefresh || this.checkingPictures ||
        this.pictureRequests > 0 || this.pictureRetryPending;
      ++this.identityRevision; ++this.pictureLoadRevision; ++this.refreshRevision;
      this.pictureRequests = 0;
    } else if (this.active) {
      if (this.checkingPictures) { this.reload(); }
      else if (this.pendingDocumentRefresh) { this.refreshDocument(); }
    }
  }
  private refreshDocument(): void {
    const revision = ++this.refreshRevision;
    this.pendingDocumentRefresh = true;
    if (!this.attached || !this.active || !this.pictureForeground) { return; }
    // Wait through one committed frame so blockNetwork is applied first.
    // onIdle can be deferred indefinitely while a large email is rendering;
    // two onFrame callbacks preserve that ordering without waiting for idle.
    this.getUIContext().postFrameCallback(new HtmlRefreshFrame(() => {
      if (!this.active || !this.attached || !this.pictureForeground || revision !== this.refreshRevision) { return; }
      this.getUIContext().postFrameCallback(new HtmlRefreshFrame(() => {
        if (!this.active || !this.attached || !this.pictureForeground || revision !== this.refreshRevision) { return; }
        // ArkWeb refresh() can reuse an intercepted main document without
        // asking the interceptor again. A new local URL always loads current
        // HTML; remote picture URLs and the account cache keys stay unchanged.
        this.documentUrl = `https://mail.invalid/message.html?view=${revision}`;
        try { this.controller.loadUrl(this.documentUrl); this.pendingDocumentRefresh = false; this.pictureRetryPending = false; }
        catch (_) { /* Retry once the controller is attached again, or on the next explicit click. */ }
      }));
    }));
  }
  private attachController(): void {
    this.attached = true;
    if (this.pendingDocumentRefresh) { this.refreshDocument(); }
  }
  private async reload(): Promise<void> {
    const cache = this.pictureCache, accountId = this.accountId, messageKey = this.messageKey;
    if (this.configuredRevision === this.identityRevision && this.configuredHtml === this.html &&
      this.configuredAccount === accountId && this.configuredMessage === messageKey && this.configuredCache === cache) { return; }
    this.releasePictures();
    const revision = ++this.identityRevision;
    this.configuredRevision = revision; this.configuredHtml = this.html;
    this.configuredAccount = accountId; this.configuredMessage = messageKey; this.configuredCache = cache;
    this.pictureOwnerCache = cache; this.pictureOwnerAccount = accountId; this.pictureOwnerMessage = messageKey;
    this.remoteImages = false; this.checkingPictures = true; this.savingPictures = false; this.pictureSaveFailed = false;
    ++this.pictureLoadRevision; this.pictureRequests = 0; this.pictureRetryPending = false;
    this.pictureFailureReasons.clear(); this.pictureFailureSummary = '';
    this.refreshDocument();
    let allowed = false;
    try { if (cache && accountId && messageKey) { allowed = await cache.allowed(accountId, messageKey); } }
    catch (_) { /* Keep remote content blocked when the saved choice cannot be read. */ }
    if (!this.active || !this.pictureForeground || revision !== this.identityRevision) { return; }
    this.remoteImages = allowed; this.checkingPictures = false;
    // The blocked document was already requested above. Unchanged permission
    // must not parse and lay it out again after a slow storage read.
    if (allowed) { this.refreshDocument(); }
  }
  private async loadPictures(): Promise<void> {
    if (this.savingPictures || !this.active || !this.pictureForeground) { return; }
    const revision = this.identityRevision;
    const cache = this.pictureCache, accountId = this.accountId, messageKey = this.messageKey;
    this.savingPictures = true; this.pictureSaveFailed = false;
    try {
      if (cache && accountId && messageKey) { await cache.allow(accountId, messageKey); }
      if (!this.active || revision !== this.identityRevision) { return; }
      this.remoteImages = true; this.refreshDocument();
    } catch (_) {
      if (this.active && revision === this.identityRevision) { this.pictureSaveFailed = true; }
    } finally { if (this.active && revision === this.identityRevision) { this.savingPictures = false; } }
  }
  private hasPictures(): boolean {
    // Download counters and error summaries can update for every image. The
    // unchanged HTML only needs its remote-reference scan once.
    if (this.picturesHtml !== this.html) {
      this.picturesHtml = this.html; this.picturesPresent = hasRemotePictures(this.html);
    }
    return this.picturesPresent;
  }
  private refreshPictures(): void {
    if (!this.active || !this.pictureForeground || !this.remoteImages || this.checkingPictures) { return; }
    // Re-render from saved bytes and retry only missing pictures. Successful
    // downloads are immutable until cache expiry; an in-flight missing image
    // is joined, so repeated clicks cannot start another download.
    ++this.pictureLoadRevision; this.pictureRequests = 0; this.pictureRetryPending = true;
    // Keep failures visible until their replacements succeed. If ArkWeb cannot
    // load the new document, the user must still be able to retry.
    this.refreshDocument();
  }
  @Builder
  private pictureControl() {
    if (!this.checkingPictures && !this.remoteImages && this.hasPictures()) {
      Column() {
        Row({ space: 10 }) {
          Text(this.label('remote_pictures_hidden')).fontSize(12).fontColor($r('app.color.mail_text_secondary')).layoutWeight(1)
          Button(this.label('load_pictures')).id('load-pictures').buttonStyle(ButtonStyleMode.TEXTUAL).height(44)
            .fontSize(13).fontColor($r('app.color.mail_accent')).backgroundColor(Color.Transparent).padding(0)
            .enabled(!this.savingPictures).onClick(() => this.loadPictures())
        }.constraintSize({ minHeight: 44 }).width('100%')
        Divider().color($r('app.color.mail_divider'))
      }.padding({ left: htmlContentInset(this.contentInset), right: htmlContentInset(this.contentInset) })
        .margin({ bottom: 12 }).width('100%')
      if (this.pictureSaveFailed) {
        Text(this.label('cache_save_error')).fontSize(13).fontColor($r('app.color.mail_text_secondary'))
          .padding({ left: htmlContentInset(this.contentInset), right: htmlContentInset(this.contentInset), bottom: 12 })
      }
    } else if (!this.checkingPictures && this.remoteImages && this.hasPictures() &&
      (this.pictureRetryPending || this.pictureRequests > 0 || this.pictureFailureSummary !== '')) {
      Row() {
        if (this.pictureRequests > 0) {
          Text(this.label('pictures_loading')).fontSize(12).fontColor($r('app.color.mail_text_secondary')).layoutWeight(1)
        } else { Blank().layoutWeight(1) }
        // Cache reads also increment the loading counter. They must not make
        // the retry button flash when reopening a completely saved message.
        if (this.pictureRetryPending || this.pictureFailureSummary !== '') {
          Button(this.label('refresh_pictures'))
            .id('refresh-pictures').buttonStyle(ButtonStyleMode.TEXTUAL).height(44)
            .fontSize(13).fontColor($r('app.color.mail_accent')).backgroundColor(Color.Transparent).padding(0)
            .onClick(() => this.refreshPictures())
        }
      }.padding({ left: htmlContentInset(this.contentInset), right: htmlContentInset(this.contentInset) })
        .margin({ bottom: 12 }).width('100%')
      if (this.pictureFailureSummary) {
        Text(this.pictureFailureSummary).id('picture-failure-summary').fontSize(12)
          .fontColor($r('app.color.mail_text_secondary')).width('100%')
          .padding({ left: htmlContentInset(this.contentInset), right: htmlContentInset(this.contentInset), bottom: 12 })
      }
    }
  }

  private recordPictureResult(url: string, result: PictureLoadResult): void {
    // The screenshot-readable summary contains only fixed categories and HTTP
    // codes, never image URLs, provider responses or account details.
    let reason = '';
    if (result.failure === 'server') {
      reason = this.label('picture_error_server') + (result.status ? ` ${result.status}` : '');
    } else if (result.failure === 'network') { reason = this.label('picture_error_network'); }
    else if (result.failure === 'format') { reason = this.label('picture_error_format'); }
    else if (result.failure === 'size') { reason = this.label('picture_error_size'); }
    else if (result.failure === 'storage') { reason = this.label(result.picture ? 'cache_save_error' : 'picture_error_storage'); }
    else if (result.failure) { reason = this.label('picture_error_blocked'); }
    // A usable saved copy is a successful display, even if a separate cache
    // caller attempted a replacement and returned its failed network status.
    if (reason && (!result.picture || result.failure === 'storage')) { this.pictureFailureReasons.set(url, reason); }
    else { this.pictureFailureReasons.delete(url); }
    const reasons = Array.from(new Set(this.pictureFailureReasons.values()));
    this.pictureFailureSummary = reasons.length > 0 ?
      `${this.label('pictures_failed')} (${this.pictureFailureReasons.size}): ${reasons.join(' · ')}` : '';
  }

  private blockNavigation(request: WebResourceRequest): boolean {
    const target = request.getRequestUrl();
    // The local document and its anchors stay in the reader. Only an actual
    // user tap may leave it; resources and unsolicited navigations never do.
    if (target === this.documentUrl || target.startsWith(this.documentUrl + '#')) { return false; }
    if (this.active && this.pictureForeground && request.isMainFrame() && request.isRequestGesture() &&
      this.externalWebLink(target)) { this.launchLink(target); }
    return true;
  }

  private externalWebLink(url: string): boolean {
    return url.length <= 8192 && !/[\u0000-\u0020\u007f\\]/.test(url) &&
      /^https?:\/\/[^\s\\\/?#@]+(?:[\/?#]|$)/i.test(url) && this.remotePictureUrl(url);
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

  private remotePictureUrl(url: string): boolean {
    // The generated document has no network-backed resources. Browser icon
    // probes and unresolved relative URLs must not become picture downloads.
    return /^https?:\/\//i.test(url) && !/^https?:\/\/mail\.invalid(?::[0-9]+)?(?:[/?#]|$)/i.test(url);
  }

  private document(): string {
    if (this.preparedSource !== this.html || this.preparedLanguage !== this.languageRevision) {
      this.preparedBody = prepareMailHtml(this.html, this.label('show_quoted_text'), this.label('hide_quoted_text'));
      this.preparedSource = this.html; this.preparedLanguage = this.languageRevision;
    }
    return preparedMailDocument(this.preparedBody, this.remoteImages, this.contentInset);
  }

  private async cachedPicture(response: WebResourceResponse, cache: PictureCache,
    accountId: string, messageKey: string, url: string): Promise<void> {
    if (!this.active || !this.pictureForeground) {
      try {
        response.setResponseData(''); response.setResponseCode(403); response.setReasonMessage('Blocked');
        response.setResponseIsReady(true);
      } catch (_) { /* The hidden document may already be discarded. */ }
      return;
    }
    // The captured account/message owns the download even after navigation.
    // ArkWeb gets only cached image bytes, never provider cookies or headers.
    const revision = this.pictureLoadRevision, identity = this.identityRevision;
    this.pictureRequests++;
    let downloadFinished = false;
    try {
      const result = await cache.loadWithStatus(accountId, messageKey, url);
      downloadFinished = true;
      const picture = result.picture;
      if (this.active && revision === this.pictureLoadRevision && identity === this.identityRevision) {
        this.recordPictureResult(url, result);
      }
      response.setResponseData(picture ? picture.data : '');
      response.setResponseMimeType(picture ? picture.mimeType : 'text/plain');
      response.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-store' }]);
      response.setResponseCode(picture ? 200 : 403);
      response.setReasonMessage(picture ? 'OK' : 'Blocked');
    } catch (_) {
      if (!downloadFinished && this.active && revision === this.pictureLoadRevision && identity === this.identityRevision) {
        this.recordPictureResult(url, { picture: null, failure: 'network', status: 0 });
      }
      try {
        response.setResponseData(''); response.setResponseMimeType('text/plain');
        response.setResponseCode(403); response.setReasonMessage('Blocked');
      } catch (_) { /* ArkWeb may already have discarded the previous document. */ }
    } finally {
      if (this.active && revision === this.pictureLoadRevision && identity === this.identityRevision) {
        this.pictureRequests = Math.max(0, this.pictureRequests - 1);
      }
      // Native response setters can fail after a reload. Their lifetime must
      // never prevent loading-state cleanup or disable a subsequent retry.
      try { response.setResponseIsReady(true); } catch (_) {}
    }
  }

  @Builder
  private content() {
    Web({ src: this.initialDocumentUrl, controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
      .id('html-mail').width('100%').height('100%').layoutMode(this.fitContent ? WebLayoutMode.FIT_CONTENT : WebLayoutMode.NONE)
      .wideViewModeAccess(true).overviewModeAccess(true)
      // ArkWeb defaults to light even when the surrounding native page is dark.
      // Auto follows theme changes in place; forced adaptation also handles
      // sender-authored white tables without reloading mail or its pictures.
      .darkMode(WebDarkMode.Auto).forceDarkAccess(true)
      .backgroundColor($r('app.color.mail_background'))
      // Keep inline data images enabled. Network requests are gated separately
      // by blockNetwork, CSP, and the request interceptor.
      .javaScriptAccess(false).blockNetwork(!this.remoteImages || !this.pictureForeground).onlineImageAccess(true)
      .fileAccess(false).domStorageAccess(false).databaseAccess(false)
      // Resource bytes and consent live in the encrypted account cache, so the
      // browser cache never grants another message implicit permission.
      .geolocationAccess(false).mixedMode(MixedMode.All).cacheMode(CacheMode.Online).multiWindowAccess(false)
      .onPermissionRequest((event) => event.request.deny())
      .onShowFileSelector(() => true)
      .onLoadIntercept((event) => this.blockNavigation(event.data))
      .onInterceptRequest((event) => {
        const document = this.active && this.pictureForeground && event.request.isMainFrame() && event.request.getRequestUrl() === this.documentUrl;
        if (!document && /^data:image\//i.test(event.request.getRequestUrl())) { return null; }
        if (!document && this.active && this.pictureForeground && !event.request.isMainFrame() && this.remoteImages && this.remotePictureUrl(event.request.getRequestUrl())) {
          const cache = this.pictureCache;
          if (cache && this.accountId && this.messageKey) {
            const response = new WebResourceResponse();
            response.setResponseIsReady(false);
            this.cachedPicture(response, cache, this.accountId, this.messageKey, event.request.getRequestUrl());
            return response;
          }
          // Standalone synthetic previews have no account persistence service.
          return null;
        }
        const response = new WebResourceResponse();
        response.setResponseData(document ? this.document() : '');
        response.setResponseHeader([{ headerKey: 'Cache-Control', headerValue: 'no-store' }]);
        response.setResponseEncoding('UTF-8'); response.setResponseMimeType('text/html');
        response.setResponseCode(document ? 200 : 403); response.setReasonMessage(document ? 'OK' : 'Blocked');
        return response;
      })
      .onControllerAttached(() => this.attachController())
  }
  build() {
    if (this.fitContent) {
      Column() { this.pictureControl(); this.content() }.width('100%')
    } else {
      Column() { this.pictureControl(); Column() { this.content() }.layoutWeight(1).width('100%') }.width('100%').height('100%')
    }
  }
}
