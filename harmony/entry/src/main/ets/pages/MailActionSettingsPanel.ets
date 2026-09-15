// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore } from '../data/AccountStore';

@Component
export struct MailActionSettingsPanel {
  @Prop @Watch('load') accountId: string = '';
  store: AccountStore = new AccountStore();
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private action: string = 'archive';
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private failed: boolean = false;
  private active: boolean = true;
  private revision: number = 0;
  aboutToAppear(): void { this.active = true; this.load(); }
  aboutToDisappear(): void { this.active = false; ++this.revision; }
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private async load(): Promise<void> {
    const accountId = this.accountId, revision = ++this.revision;
    this.ready = false; this.busy = false; this.failed = false; this.action = 'archive';
    try {
      const action = await this.store.mailAction(accountId);
      if (!this.active || revision !== this.revision || accountId !== this.accountId) { return; }
      this.action = action; this.ready = true;
    } catch (_) { if (this.active && revision === this.revision) { this.failed = true; } }
  }
  private async choose(action: string): Promise<void> {
    if (!this.ready || this.busy) { return; }
    const accountId = this.accountId, revision = this.revision, previous = this.action;
    this.busy = true; this.failed = false; this.action = action;
    try {
      await this.store.saveMailAction(accountId, action);
      AppStorage.setOrCreate('mailActionSettingsRevision', (AppStorage.get<number>('mailActionSettingsRevision') || 0) + 1);
      if (this.active && revision === this.revision && accountId === this.accountId) { this.action = action; }
    } catch (_) { if (this.active && revision === this.revision) { this.action = previous; this.failed = true; } }
    finally { if (this.active && revision === this.revision) { this.busy = false; } }
  }
  build() {
    Column({ space: 8 }) {
      Text(this.label('mail_swipe_action')).fontSize(15).width('100%').fontColor($r('app.color.mail_text_secondary'))
      Select([{ value: this.label('archive') }, { value: this.label('delete') }])
        .id('mail-swipe-action').selected(this.action === 'delete' ? 1 : 0).value(this.label(this.action))
        .width('100%').enabled(this.ready && !this.busy).onSelect(index => this.choose(index === 1 ? 'delete' : 'archive'))
      Text(this.label('mail_swipe_action_help')).fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      if (this.failed) {
        Text(this.label('mail_action_save_error')).fontSize(14).width('100%')
        if (!this.ready) { Button(this.label('retry')).onClick(() => this.load()) }
      }
    }.width('100%')
  }
}
