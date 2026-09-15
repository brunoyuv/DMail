// Main-HAP synthetic UI host. Main resource IDs follow the shipping app's
// resource path; the test feature only drives this isolated application's UI.
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NavigationFixtureState } from '../support/NavigationClient';
import { PictureRefreshState } from '../support/PictureRefreshState';
import { StaticPictureState } from '../support/StaticPictureState';
import { InboxIdleState } from '../support/InboxIdleState';
import { HtmlLinkState } from '../support/HtmlLinkState';
import { HtmlScrollPowerState } from '../support/HtmlScrollPowerState';
import { HtmlPictureScrollState } from '../support/HtmlPictureScrollState';
import { MailInboxUpdates } from '../mail/notifications/MailInboxUpdates';
import { MailBannerNotice } from '../mail/notifications/MailBannerNotice';
import { MailUnreadStatus } from '../mail/MailUnreadStatus';
import { AccountStore } from '../data/AccountStore';

function colorHex(read: () => number): string {
  try { return (read() >>> 0).toString(16).padStart(8, '0'); }
  catch (_) { return 'unavailable'; }
}

export default class EntryAbility extends UIAbility {
  private stageCreated: (stage: window.WindowStage) => void = () => {};
  private stageReady: Promise<window.WindowStage> = new Promise((resolve) => { this.stageCreated = resolve; });
  onWindowStageCreate(stage: window.WindowStage): void { this.prepareWindow(stage, this.stageReady); }
  onWindowStageDestroy(): void {
    // A recreated ability window must not keep the first, destroyed stage.
    this.stageReady = new Promise((resolve) => { this.stageCreated = resolve; });
  }
  private async prepareWindow(stage: window.WindowStage, ready: Promise<window.WindowStage>): Promise<void> {
    try {
      await stage.loadContent('pages/TestLoadingFixture');
      if (ready === this.stageReady) { this.stageCreated(stage); }
    } catch (_) { /* A destroyed startup stage is replaced by its next create callback. */ }
  }
  private async loadFixture(page: string): Promise<void> {
    const ready = this.stageReady;
    const stage = await ready;
    if (ready !== this.stageReady) { await (await this.stageReady).loadContent(page); return; }
    try { await stage.loadContent(page); }
    catch (error) {
      if (ready === this.stageReady) { throw error as Error; }
      await (await this.stageReady).loadContent(page);
    }
  }
  async showHtmlThemeFixture(): Promise<void> { await this.loadFixture('pages/HtmlThemeFixture'); }
  async showHtmlImageSizingFixture(): Promise<void> { await this.loadFixture('pages/HtmlImageSizingFixture'); }
  async showHtmlLinkFixture(): Promise<void> {
    HtmlLinkState.reset(); await this.loadFixture('pages/HtmlLinkFixture');
  }
  async showLongHtmlLinkFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    HtmlLinkState.reset(true); await this.loadFixture('pages/HtmlLinkFixture');
  }
  htmlLinkOpenCount(): number { return HtmlLinkState.opened.length; }
  htmlLinkLastUrl(): string { return HtmlLinkState.opened[HtmlLinkState.opened.length - 1] ?? ''; }
  htmlLinkDocumentCount(): number { return HtmlLinkState.documentLoads; }
  htmlLinkLoadSummary(): string { return `${HtmlLinkState.controllerLoads},${HtmlLinkState.documentLoads}`; }
  htmlLinkLength(): number { return HtmlLinkState.htmlLength; }
  htmlLinkScrollEvents(): number { return HtmlLinkState.scrollEvents; }
  htmlLinkScrollMaximum(): number { return HtmlLinkState.scrollMaximum; }
  htmlLinkDiagnostics(): string { return HtmlLinkState.diagnostics(); }
  async showHtmlScrollPowerFixture(mode: string): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    HtmlScrollPowerState.reset(mode); await this.loadFixture('pages/HtmlScrollPowerFixture');
  }
  htmlScrollPowerLoads(): string { return HtmlScrollPowerState.loads(); }
  htmlScrollPowerDocumentCount(): number { return HtmlScrollPowerState.documentLoads; }
  htmlScrollPowerLength(): number { return HtmlScrollPowerState.htmlLength; }
  htmlScrollPowerEvents(): number { return HtmlScrollPowerState.scrollEvents; }
  htmlScrollPowerMaximum(): number { return HtmlScrollPowerState.scrollMaximum; }
  async showHtmlPictureScrollFixture(mode: string): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    await HtmlPictureScrollState.open(this.context);
    HtmlScrollPowerState.reset(mode); await this.loadFixture('pages/HtmlPictureScrollFixture');
  }
  async closeHtmlPictureScrollFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture'); await HtmlPictureScrollState.close();
  }
  htmlPictureScrollCounts(): string { return HtmlPictureScrollState.counts(); }
  htmlPictureScrollGoodRequests(): number { return HtmlPictureScrollState.goodRequests; }
  htmlPictureScrollMissingRequests(): number { return HtmlPictureScrollState.missingRequests; }
  htmlPictureScrollTrackerRequests(): number { return HtmlPictureScrollState.trackerRequests; }
  htmlPictureScrollCloseTapMs(): number { return HtmlPictureScrollState.closeTapMs; }
  htmlPictureScrollCloseVisibleMs(): number { return HtmlPictureScrollState.closeVisibleMs; }
  htmlPictureScrollCacheIntact(): Promise<boolean> { return HtmlPictureScrollState.cacheIntact(); }
  htmlPictureScrollIdle(): Promise<void> { return HtmlPictureScrollState.idle(); }
  async showNavigationFixture(): Promise<void> { await this.loadFixture('pages/NavigationFixture'); }
  async showReviewInboxFixture(): Promise<void> { await this.loadFixture('pages/ReviewInboxFixture'); }
  async showInboxLatencyFixture(): Promise<void> { await this.loadFixture('pages/InboxLatencyFixture'); }
  async showInboxIdleFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    await InboxIdleState.open(this.context); await this.loadFixture('pages/InboxIdleFixture');
  }
  inboxIdleCounts(): string { return InboxIdleState.counts(); }
  inboxIdleCompleted(): number { return InboxIdleState.completed(); }
  inboxIdleBodyTimes(): string { return InboxIdleState.times(); }
  inboxIdleSealAndVerify(): Promise<boolean> { return InboxIdleState.sealAndVerify(); }
  requestInboxIdleUpdate(): void { InboxIdleState.requestUpdate(); }
  inboxIdleSetForeground(visible: boolean): void { InboxIdleState.setForeground(visible); }
  inboxIdleLargeRowProof(): Promise<string> { return InboxIdleState.largeRowProof(this.context); }
  inboxIdleStorageProof(): Promise<string> { return InboxIdleState.storageProof(this.context); }
  async reopenInboxIdleFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    await InboxIdleState.reopen(this.context); await this.loadFixture('pages/InboxIdleFixture');
  }
  async closeInboxIdleFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture'); await InboxIdleState.close(this.context);
  }
  async showStoreScreenshotFixture(): Promise<void> { await this.loadFixture('pages/StoreScreenshotFixture'); }
  async hideNavigationFixture(): Promise<void> { await this.loadFixture('pages/TestLoadingFixture'); }
  async showPictureRefreshFixture(): Promise<void> {
    await PictureRefreshState.open(this.context); await this.loadFixture('pages/PictureRefreshFixture');
  }
  pictureRefreshTrace(): string { return PictureRefreshState.trace(); }
  pictureRefreshRequestCount(): number { return PictureRefreshState.requests; }
  pictureRefreshNonContentRequests(): number { return PictureRefreshState.nonContentRequests; }
  pictureRefreshRequestCounts(): string { return PictureRefreshState.requestCounts(); }
  holdPictureRefreshFailures(): void { PictureRefreshState.holdFailures(); }
  recoverPictureRefreshMissing(): void { PictureRefreshState.recoverMissing(); }
  releasePictureRefresh(): void { PictureRefreshState.release(); }
  async reopenPictureRefreshUnavailable(): Promise<void> {
    PictureRefreshState.makeUnavailable();
    await this.loadFixture('pages/TestLoadingFixture');
    await this.loadFixture('pages/PictureRefreshFixture');
  }
  async closePictureRefreshFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture'); await PictureRefreshState.close();
  }
  pictureRefreshCacheIntact(expectedCount: number): Promise<boolean> { return PictureRefreshState.cacheIntact(expectedCount); }
  async showStaticPictureFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture');
    await StaticPictureState.open(this.context); await this.loadFixture('pages/StaticPictureFixture');
  }
  staticPictureRequestCounts(): string { return StaticPictureState.requestCounts(); }
  staticPictureNonContentRequests(): number { return StaticPictureState.nonContentRequests; }
  staticPictureLoadCounts(): string { return StaticPictureState.loadCounts(); }
  staticPictureWorkCounts(): string { return StaticPictureState.workCounts(); }
  staticPictureSyncCounts(): string { return StaticPictureState.syncCounts(); }
  staticPictureDocumentIntact(): Promise<boolean> { return StaticPictureState.documentIntact(); }
  staticPictureSavedDocumentReady(): boolean { return StaticPictureState.savedDocumentReady(); }
  staticPictureMaximumScroll(): number { return StaticPictureState.maximumScroll(); }
  staticPictureCacheIntact(count: number): Promise<boolean> { return StaticPictureState.cacheIntact(count); }
  staticPictureTrace(): string { return StaticPictureState.trace(); }
  holdStaticPictures(): void { StaticPictureState.holdFailures(); }
  releaseStaticPictures(): void { StaticPictureState.release(); }
  recoverStaticPictures(): void { StaticPictureState.recoverMissing(); }
  staticPictureForeground(foreground: boolean): void { StaticPictureState.setForeground(foreground); }
  staticPictureReturnToTop(): void { StaticPictureState.returnToTop(); }
  async reopenStaticPictureUnavailable(): Promise<void> {
    StaticPictureState.makeUnavailable(); await this.loadFixture('pages/TestLoadingFixture');
    await StaticPictureState.recreateCache(); await this.loadFixture('pages/StaticPictureFixture');
  }
  async closeStaticPictureFixture(): Promise<void> {
    await this.loadFixture('pages/TestLoadingFixture'); await StaticPictureState.close();
  }
  resetNavigationFixtureState(): void { NavigationFixtureState.reset(); }
  navigationCallCount(): number { return NavigationFixtureState.calls.length; }
  navigationClientCount(): number { return NavigationFixtureState.created.length; }
  navigationCallSummary(): string { return NavigationFixtureState.calls.join(','); }
  navigationViolationCount(): number { return NavigationFixtureState.violations.length; }
  enableNavigationReaderRecovery(): void { NavigationFixtureState.readerRecovery = true; }
  setNavigationReaderOffline(): void {
    if (!NavigationFixtureState.readerRecovery) { throw new Error('Synthetic reader recovery is not enabled'); }
    NavigationFixtureState.betaOffline = true;
  }
  setNavigationInboxSize(size: number): void {
    if (!Number.isInteger(size) || size < 1 || size > 6) { throw new Error('Invalid synthetic inbox size'); }
    NavigationFixtureState.betaInboxSize = size;
  }
  requestNavigationInboxUpdate(accountId: string): void { MailInboxUpdates.request(accountId); }
  setNavigationInboxForeground(foreground: boolean): void { MailInboxUpdates.setForeground(foreground); }
  showNavigationBanner(accountId: string, version: number): void { MailBannerNotice.show(accountId, version); }
  dismissNavigationBanner(): void { MailBannerNotice.dismiss(); }
  async refreshNavigationUnread(): Promise<void> {
    const store = new AccountStore('navigation_ui_test.db');
    await store.open(this.context);
    try { await MailUnreadStatus.refresh(store); } finally { await store.close(); }
  }
  enableRepeatedNavigationKeywords(): void { NavigationFixtureState.repeatKeywordActions = true; }
  holdNavigationKeywords(hold: boolean): void {
    NavigationFixtureState.holdKeywords = hold;
    if (!hold) { NavigationFixtureState.completeKeywords(); }
  }
  navigationPendingKeywords(): number { return NavigationFixtureState.pendingKeywords; }
  holdNavigationPages(hold: boolean): void {
    NavigationFixtureState.holdPages = hold;
    if (!hold) { NavigationFixtureState.completePages(); }
  }
  navigationPendingPages(): number { return NavigationFixtureState.pendingPages; }
  enableNavigationSentLatency(): void { NavigationFixtureState.sentLatency = true; NavigationFixtureState.holdSentPages = true; }
  navigationPendingSentPages(): number { return NavigationFixtureState.pendingSentPages; }
  releaseNavigationSentPages(): void {
    NavigationFixtureState.holdSentPages = false; NavigationFixtureState.completeSentPages();
  }
  themeBackground(): number { return this.context.resourceManager.getColorSync($r('app.color.mail_background').id) >>> 0; }
  themeText(): number { return this.context.resourceManager.getColorSync($r('app.color.mail_text_primary').id) >>> 0; }
  themeResourceDiagnostics(): string {
    const resources = this.context.resourceManager;
    const background = $r('app.color.mail_background');
    const text = $r('app.color.mail_text_primary');
    return JSON.stringify({ module: 'entry', mode: this.context.config.colorMode,
      backgroundId: background.id, textId: text.id,
      backgroundByName: colorHex(() => resources.getColorByNameSync('mail_background')),
      backgroundById: colorHex(() => resources.getColorSync(background.id)),
      textByName: colorHex(() => resources.getColorByNameSync('mail_text_primary')),
      textById: colorHex(() => resources.getColorSync(text.id)) });
  }
}
