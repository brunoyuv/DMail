import { UIAbility } from '@kit.AbilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { display, window } from '@kit.ArkUI';
import { AccountStore } from '../../../main/ets/data/AccountStore';
export default class IMAPTestAbility extends UIAbility {
  private stageCreated: (stage: window.WindowStage) => void = () => {};
  private stageReady: Promise<window.WindowStage> = new Promise((resolve) => { this.stageCreated = resolve; });
  onWindowStageCreate(stage: window.WindowStage): void {
    // Show content immediately while a test prepares its synthetic account.
    this.prepareWindow(stage);
  }
  private async prepareWindow(stage: window.WindowStage): Promise<void> {
    const screen = display.getDefaultDisplaySync();
    // The physical Pura X cover screen has no status bar (user screenshot).
    if (deviceInfo.abiList.includes('x86_64') && screen.width === 980 && screen.height === 980) {
      await stage.getMainWindowSync().setWindowSystemBarEnable([]);
      await stage.getMainWindowSync().setSpecificSystemBarEnabled('navigationIndicator', false);
    }
    await stage.loadContent('pages/TestLoadingFixture');
    this.stageCreated(stage);
  }
  async showMailFeaturesFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/MailFeaturesFixture'); }
  async showHtmlConsentFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/HtmlConsentFixture'); }
  async showHtmlThemeFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/HtmlThemeFixture'); }
  async showNavigationFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/NavigationFixture'); }
  async hideNavigationFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/TestLoadingFixture'); }
  async showDiscoveryFixture(): Promise<void> { await (await this.stageReady).loadContent('pages/DiscoveryFixture'); }
  async showMailboxFixture(): Promise<void> {
    await (await this.stageReady).loadContent('pages/MailboxFixture');
  }
  async showFixture(reset: boolean): Promise<void> {
    const stage = await this.stageReady;
    const store = new AccountStore('imap_ui_test.db'); await store.open(this.context);
    try { if (reset) { for (const account of await store.list()) { await store.remove(account.id); } } }
    finally { await store.close(); }
    await stage.loadContent('pages/AccountFixture');
  }
}
