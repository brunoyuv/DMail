// Main-HAP synthetic UI host. Main resource IDs follow the shipping app's
// resource path; the test feature only drives this isolated application's UI.
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { NavigationFixtureState } from '../support/NavigationClient';
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
  async showNavigationFixture(): Promise<void> { await this.loadFixture('pages/NavigationFixture'); }
  async hideNavigationFixture(): Promise<void> { await this.loadFixture('pages/TestLoadingFixture'); }
  resetNavigationFixtureState(): void { NavigationFixtureState.reset(); }
  navigationCallCount(): number { return NavigationFixtureState.calls.length; }
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
