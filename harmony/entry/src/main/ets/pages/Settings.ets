// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { AppLanguage } from '../settings/AppLanguage';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { NotificationSettingsPanel } from './NotificationSettingsPanel';

@Component
export struct Settings {
  account: SavedAccount = new SavedAccount();
  store: AccountStore = new AccountStore();
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private choice: string = AppLanguage.choice;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  @State private accounts: SavedAccount[] = [];
  @State private selectedAccount: string = '';
  @State private senderName: string = '';
  @State private signature: string = '';
  @State private compositionReady: boolean = false;
  @State private compositionFailed: boolean = false;
  private active: boolean = true;
  private accountGeneration: number = 0;
  private saveRevision: number = 0;

  aboutToAppear(): void { this.active = true; this.loadAccounts(); }
  aboutToDisappear(): void { this.active = false; ++this.accountGeneration; }
  private async loadAccounts(): Promise<void> {
    try {
      const accounts = await this.store.list();
      if (!this.active) { return; }
      this.accounts = accounts;
      const selected = accounts.find(value => value.id === this.account.id) || accounts[0];
      if (selected) { await this.chooseAccount(selected.id); }
    } catch (_) { if (this.active) { this.compositionFailed = true; } }
  }
  private async chooseAccount(accountId: string): Promise<void> {
    const generation = ++this.accountGeneration;
    this.selectedAccount = accountId; this.compositionReady = false; this.compositionFailed = false;
    this.senderName = ''; this.signature = '';
    try {
      const settings = await this.store.composition(accountId);
      if (this.active && generation === this.accountGeneration) {
        this.senderName = settings.senderName; this.signature = settings.signature; this.compositionReady = true;
      }
    } catch (_) { if (this.active && generation === this.accountGeneration) { this.compositionFailed = true; } }
  }
  private async saveComposition(): Promise<void> {
    if (!this.compositionReady) { return; }
    const accountId = this.selectedAccount, generation = this.accountGeneration, revision = ++this.saveRevision;
    try {
      await this.store.saveComposition(accountId, { senderName: this.senderName, signature: this.signature });
      if (this.active && generation === this.accountGeneration && revision === this.saveRevision) { this.compositionFailed = false; }
    } catch (_) {
      if (this.active && generation === this.accountGeneration && revision === this.saveRevision) { this.compositionFailed = true; }
    }
  }
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private async choose(value: string): Promise<void> {
    this.busy = true; this.failed = false;
    try {
      await AppLanguage.set(this.getUIContext().getHostContext() as common.Context, value);
      this.choice = value;
      // Resource configuration changes are delivered asynchronously by ArkUI.
      setTimeout(() => AppStorage.setOrCreate('appLanguageRevision', this.languageRevision + 1), 100);
    } catch (_) { this.failed = true; }
    finally { this.busy = false; }
  }
  @Builder
  private option(value: string, title: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(value === 'default' ? this.label('language_system') : title).layoutWeight(1).textAlign(TextAlign.Start).fontSize(17)
        if (this.choice === value) { SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('sys.color.font_emphasize')]) }
      }.width('100%').padding(16).constraintSize({ minHeight: 56 })
    }.id(`language-${value}`).width('100%').buttonStyle(ButtonStyleMode.NORMAL)
      .enabled(!this.busy).onClick(() => this.choose(value))
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.accounts.length > 0) {
          Text(this.label('composition_settings')).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
            .fontColor($r('app.color.mail_text_primary'))
          Select(this.accounts.map((value: SavedAccount): SelectOption => ({ value: value.emailAddress || value.name })))
            .id('composition-account').selected(this.accounts.findIndex(value => value.id === this.selectedAccount))
            .value(this.accounts.find(value => value.id === this.selectedAccount)?.emailAddress || this.accounts.find(value => value.id === this.selectedAccount)?.name || '')
            .onSelect(index => { if (this.accounts[index]) { this.chooseAccount(this.accounts[index].id); } }).width('100%')
          NotificationSettingsPanel({ accountId: this.selectedAccount, store: this.store })
          Text(this.label('sender_name')).fontSize(15).fontColor($r('app.color.mail_text_secondary')).width('100%')
          TextInput({ text: this.senderName, placeholder: this.label('sender_name_placeholder') })
            .id('sender-display-name').maxLength(200).enableAutoFill(false).height(48).width('100%')
            .fontColor($r('app.color.mail_text_primary')).backgroundColor($r('app.color.mail_surface'))
            .enabled(this.compositionReady).onChange(value => { this.senderName = value; this.saveComposition(); })
          Text(this.label('signature')).fontSize(15).fontColor($r('app.color.mail_text_secondary')).width('100%')
          TextArea({ text: this.signature, placeholder: this.label('signature_placeholder') })
            .id('account-signature').maxLength(8000).height(150).width('100%').fontSize(16)
            .fontColor($r('app.color.mail_text_primary')).backgroundColor($r('app.color.mail_surface'))
            .enabled(this.compositionReady).onChange(value => { this.signature = value; this.saveComposition(); })
          Text(this.label('composition_help')).fontSize(14).fontColor($r('app.color.mail_text_secondary')).width('100%')
          if (this.compositionFailed) {
            Text(this.label('composition_save_error')).fontSize(14).width('100%')
            Button(this.label('retry')).buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick(() => { if (this.compositionReady) { this.saveComposition(); } else { this.chooseAccount(this.selectedAccount); } })
          }
          Divider().color($r('app.color.mail_divider')).margin({ top: 8, bottom: 12 })
        }
        if (this.accounts.length === 0 && this.compositionFailed) {
          Text(this.label('composition_save_error')).fontSize(14).width('100%')
          Button(this.label('retry')).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => this.loadAccounts())
        }
        Text(this.label('app_language')).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
        this.option('default', this.label('language_system'))
        this.option('en', 'English')
        this.option('zh-Hans', '简体中文')
        Text(this.label('language_help')).fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
        if (this.failed) { Text(this.label('language_save_error')).fontSize(14).width('100%') }
      }.padding(20).width('100%').constraintSize({ maxWidth: 640 })
    }.id('app-settings').width('100%').height('100%').align(Alignment.Top).backgroundColor($r('app.color.mail_background'))
  }
}
