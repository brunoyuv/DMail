// MPL-2.0: https://mozilla.org/MPL/2.0/
import { webview } from '@kit.ArkWeb';
import { FrameCallback } from '@kit.ArkUI';
import { hasRemotePictures, htmlContentInset, mailDocument } from '../mail/html/HtmlDocument';
import { PictureCache } from '../data/PictureCache';

class HtmlRefreshFrame extends FrameCallback {
  private refresh: () => void;
  constructor(refresh: () => void) { super(); this.refresh = refresh; }
  onIdle(_timeLeftInNano: number): void { this.refresh(); }
}

@Component
export struct HtmlMail {
  @Prop @Watch('reload') html: string = '';
  @Prop @Watch('reload') messageKey: string = '';
  @Prop @Watch('reload') accountId: string = '';
  pictureCache?: PictureCache;
  @Prop @Watch('refreshDocument') contentInset: number = 20;
  @Prop fitContent: boolean = false;
  @StorageLink('appLanguageRevision') @Watch('refreshDocument') private languageRevision: number = 0;
  @State private remoteImages: boolean = false;
  @State private checkingPictures: boolean = true;
  @State private savingPictures: boolean = false;
  @State private pictureSaveFailed: boolean = false;
  @State private pictureRequests: number = 0;
  private pictureLoadRevision: number = 0;
  private forcePictureRefresh: boolean = false;
  private refreshedPictureUrls: Set<string> = new Set();
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private controller: webview.WebviewController = new webview.WebviewController();
  private attached: boolean = false;
  private refreshRevision: number = 0;
  private identityRevision: number = 0;
  private active: boolean = false;
  private readonly documentUrl: string = 'https://mail.invalid/message.html';

  aboutToAppear(): void { this.active = true; this.reload(); }
  aboutToDisappear(): void { this.active = false; this.attached = false; ++this.refreshRevision; ++this.identityRevision; }
  private refreshDocument(): void {
    const revision = ++this.refreshRevision;
    if (!this.attached) { return; }
    // Apply ArkWeb's blockNetwork property before requesting the replacement
    // document. A zero-delay timer can run before the ArkUI frame is committed.
    this.getUIContext().postFrameCallback(new HtmlRefreshFrame(() => {
      if (this.attached && revision === this.refreshRevision) { this.controller.refresh(); }
    }));
  }
  private async reload(): Promise<void> {
    const revision = ++this.identityRevision;
    const cache = this.pictureCache, accountId = this.accountId, messageKey = this.messageKey;
    this.remoteImages = false; this.checkingPictures = true; this.savingPictures = false; this.pictureSaveFailed = false;
    ++this.pictureLoadRevision; this.pictureRequests = 0; this.forcePictureRefresh = false; this.refreshedPictureUrls.clear();
    this.refreshDocument();
    let allowed = false;
    try { if (cache && accountId && messageKey) { allowed = await cache.allowed(accountId, messageKey); } }
    catch (_) { /* Keep remote content blocked when the saved choice cannot be read. */ }
    if (!this.active || revision !== this.identityRevision) { return; }
    this.remoteImages = allowed; this.checkingPictures = false; this.refreshDocument();
  }
  private async loadPictures(): Promise<void> {
    if (this.savingPictures) { return; }
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
  private hasPictures(): boolean { return hasRemotePictures(this.html); }
  private refreshPictures(): void {
    if (!this.remoteImages || this.checkingPictures || this.pictureRequests > 0) { return; }
    // Only this explicit click bypasses cached bytes. Each URL is refreshed
    // once; document/layout refreshes and ordinary reopen stay cache-first.
    ++this.pictureLoadRevision; this.forcePictureRefresh = true; this.refreshedPictureUrls.clear();
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
    } else if (!this.checkingPictures && this.remoteImages && this.hasPictures()) {
      Row() {
        Blank().layoutWeight(1)
        Button(this.label(this.pictureRequests > 0 ? 'pictures_loading' : 'refresh_pictures'))
          .id('refresh-pictures').buttonStyle(ButtonStyleMode.TEXTUAL).height(44)
          .fontSize(13).fontColor($r('app.color.mail_accent')).backgroundColor(Color.Transparent).padding(0)
          .enabled(this.pictureRequests === 0).onClick(() => this.refreshPictures())
      }.padding({ left: htmlContentInset(this.contentInset), right: htmlContentInset(this.contentInset) })
        .margin({ bottom: 12 }).width('100%')
    }
  }

  private document(): string {
    return mailDocument(this.html, this.remoteImages, this.contentInset,
      this.label('show_quoted_text'), this.label('hide_quoted_text'));
  }

  private async cachedPicture(response: WebResourceResponse, cache: PictureCache,
    accountId: string, messageKey: string, url: string): Promise<void> {
    // The captured account/message owns the download even after navigation.
    // ArkWeb gets only cached image bytes, never provider cookies or headers.
    const revision = this.pictureLoadRevision, identity = this.identityRevision;
    const refresh = this.forcePictureRefresh && !this.refreshedPictureUrls.has(url);
    if (refresh) { this.refreshedPictureUrls.add(url); }
    this.pictureRequests++;
    try {
      const picture = await cache.load(accountId, messageKey, url, refresh);
      response.setResponseData(picture ? picture.data : '');
      response.setResponseMimeType(picture ? picture.mimeType : 'text/plain');
      response.setResponseCode(picture ? 200 : 403);
      response.setReasonMessage(picture ? 'OK' : 'Blocked');
    } catch (_) {
      response.setResponseData(''); response.setResponseMimeType('text/plain');
      response.setResponseCode(403); response.setReasonMessage('Blocked');
    } finally {
      response.setResponseIsReady(true);
      if (this.active && revision === this.pictureLoadRevision && identity === this.identityRevision) {
        this.pictureRequests = Math.max(0, this.pictureRequests - 1);
      }
    }
  }

  @Builder
  private content() {
    Web({ src: this.documentUrl, controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
      .id('html-mail').width('100%').height('100%').layoutMode(this.fitContent ? WebLayoutMode.FIT_CONTENT : WebLayoutMode.NONE)
      .wideViewModeAccess(true).overviewModeAccess(true)
      // ArkWeb defaults to light even when the surrounding native page is dark.
      // Auto follows theme changes in place; forced adaptation also handles
      // sender-authored white tables without reloading mail or its pictures.
      .darkMode(WebDarkMode.Auto).forceDarkAccess(true)
      .backgroundColor($r('app.color.mail_background'))
      // Keep inline data images enabled. Network requests are gated separately
      // by blockNetwork, CSP, and the request interceptor.
      .javaScriptAccess(false).blockNetwork(!this.remoteImages).onlineImageAccess(true)
      .fileAccess(false).domStorageAccess(false).databaseAccess(false)
      // Resource bytes and consent live in the encrypted account cache, so the
      // browser cache never grants another message implicit permission.
      .geolocationAccess(false).mixedMode(MixedMode.All).cacheMode(CacheMode.Online)
      .onPermissionRequest((event) => event.request.deny())
      .onShowFileSelector(() => true)
      .onLoadIntercept((event) => event.data.isRequestGesture() || event.data.getRequestUrl() !== this.documentUrl)
      .onInterceptRequest((event) => {
        const document = event.request.isMainFrame() && event.request.getRequestUrl() === this.documentUrl;
        if (!document && /^data:image\//i.test(event.request.getRequestUrl())) { return null; }
        if (!document && !event.request.isMainFrame() && this.remoteImages && /^https?:\/\//i.test(event.request.getRequestUrl())) {
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
        response.setResponseEncoding('UTF-8'); response.setResponseMimeType('text/html');
        response.setResponseCode(document ? 200 : 403); response.setReasonMessage(document ? 'OK' : 'Blocked');
        return response;
      })
      .onControllerAttached(() => { this.attached = true; })
  }
  build() {
    if (this.fitContent) {
      Column() { this.pictureControl(); this.content() }.width('100%')
    } else {
      Column() { this.pictureControl(); Column() { this.content() }.layoutWeight(1).width('100%') }.width('100%').height('100%')
    }
  }
}
