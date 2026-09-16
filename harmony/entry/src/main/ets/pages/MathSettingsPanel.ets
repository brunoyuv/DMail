// MPL-2.0: https://mozilla.org/MPL/2.0/
import { AccountStore } from '../data/AccountStore';
import { MathSettings } from '../data/MathSettings';

@Component
export struct MathSettingsPanel {
  @Prop @Watch('load') accountId: string = '';
  store: AccountStore = new AccountStore();
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @State private settings: MathSettings = new MathSettings();
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
    const id = this.accountId, revision = ++this.revision;
    this.ready = false; this.busy = false; this.failed = false; this.settings = new MathSettings();
    try {
      const settings = await this.store.mathSettings(id);
      if (!this.active || revision !== this.revision || id !== this.accountId) { return; }
      this.settings = settings; this.ready = true;
    } catch (_) { if (this.active && revision === this.revision) { this.failed = true; } }
  }
  private async choose(reading: boolean, format: string, renderer: string = this.settings.renderer || 'mathml'): Promise<void> {
    if (!this.ready || this.busy) { return; }
    const id = this.accountId, revision = this.revision, previous = this.settings;
    const next: MathSettings = { renderWhileReading: reading, sendFormat: format, renderer };
    this.busy = true; this.failed = false; this.settings = next;
    try { await this.store.saveMathSettings(id, next); }
    catch (_) { if (this.active && revision === this.revision) { this.settings = previous; this.failed = true; } }
    finally { if (this.active && revision === this.revision) { this.busy = false; } }
  }
  build() {
    Column({ space: 8 }) {
      Text(this.label('math_settings')).fontSize(15).width('100%').fontColor($r('app.color.mail_text_secondary'))
      Row({ space: 12 }) {
        Text(this.label('math_reading')).fontSize(16).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.settings.renderWhileReading }).id('math-reading')
          .enabled(this.ready && !this.busy).onChange(value => this.choose(value, this.settings.sendFormat))
      }.width('100%')
      Text(this.label('math_renderer')).fontSize(15).width('100%').fontColor($r('app.color.mail_text_secondary'))
      Select([{ value: this.label('math_commonhtml') }, { value: this.label('math_mathml') }])
        .id('math-renderer').selected(this.settings.renderer === 'mathml' ? 1 : 0)
        .value(this.label(this.settings.renderer === 'mathml' ? 'math_mathml' : 'math_commonhtml'))
        .width('100%').enabled(this.ready && !this.busy)
        .onSelect(index => this.choose(this.settings.renderWhileReading, this.settings.sendFormat, index === 1 ? 'mathml' : 'commonhtml'))
      Text(this.label('math_settings_help')).fontSize(14).width('100%').fontColor($r('app.color.mail_text_secondary'))
      if (this.failed) {
        Text(this.label('math_settings_error')).fontSize(14).width('100%')
        if (!this.ready) { Button(this.label('retry')).onClick(() => this.load()) }
      }
    }.width('100%')
  }
}
