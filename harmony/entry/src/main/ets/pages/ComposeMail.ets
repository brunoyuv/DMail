// MPL-2.0: https://mozilla.org/MPL/2.0/
import { HtmlMail } from './HtmlMail';
import { util } from '@kit.ArkTS';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { OutgoingDraft, SmtpSettings, SmtpError } from '../mail/smtp/NativeSmtpClient';
import { BackgroundSend } from '../mail/smtp/BackgroundSend';
import { sendFailureLabel, setSendFailure, sendFailureDiagnostic } from '../mail/smtp/SentMail';
import { RecipientRecord, recipientSuggestions, recipientToken, completeRecipient } from '../data/RecipientHistory';

@Component
export struct ComposeMail {
  account: SavedAccount = new SavedAccount();
  store: AccountStore = new AccountStore();
  onClose: (sent: boolean) => void = () => {};
  onQueued: () => void = () => {};
  tabletLayout: boolean = false;
  @StorageLink('appLanguageRevision') private languageRevision: number = 0;
  @StorageLink('mailSendRevision') @Watch('sendingChanged') private sendRevision: number = 0;
  @State private compact: boolean = false;
  @State private tablet: boolean = false;
  @State private viewportHeight: number = 600;
  @State private expandedAddresses: boolean = false;
  @State private draft: OutgoingDraft = new OutgoingDraft();
  @State private host: string = '';
  @State private port: string = '587';
  @State private tls: boolean = false;
  @State private username: string = '';
  @State private password: string = '';
  @State private setup: boolean = false;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private notice: string = '';
  @State private saveFailed: boolean = false;
  @State private recipientHistory: RecipientRecord[] = [];
  @State private recipientField: string = '';
  @State private recipientCaret: number = 0;
  private toController: TextInputController = new TextInputController();
  private ccController: TextInputController = new TextInputController();
  private bccController: TextInputController = new TextInputController();
  private initialText: string = '';
  private label(name: string): string {
    this.languageRevision;
    return this.getUIContext().getHostContext()!.resourceManager.getStringByNameSync(name);
  }
  private active: boolean = true;

  aboutToAppear(): void { this.active = true; this.initialize(); }
  aboutToDisappear(): void { this.active = false; this.password = ''; }
  private sendingChanged(): void {
    if (this.active && this.draft.state === 'sending' && !BackgroundSend.isSending(this.account.id)) { this.initialize(); }
  }
  private async initialize(): Promise<void> {
    this.loadRecipients();
    try {
      const saved = await this.store.outgoing(this.account.id, BackgroundSend.isSending(this.account.id));
      if (!this.active) { return; }
      this.draft = saved && saved.state !== 'sent' && !BackgroundSend.wasAccepted(this.account.id, saved.id) ? saved : await this.newDraft();
      if (!this.active) { return; }
      const settings = await this.store.smtp(this.account);
      if (!this.active) { return; }
      const match = /^(smtps?):\/\/([^/:]+):(\d+)$/.exec(settings.endpoint);
      if (match) { this.tls = match[1] === 'smtps'; this.host = match[2]; this.port = match[3]; }
      this.username = settings.username; this.password = settings.password;
      this.setup = false; this.expandedAddresses = this.draft.cc !== '' || this.draft.bcc !== ''; this.ready = true;
      this.notice = this.draft.state === 'sending' ? this.label('send_in_progress') : this.savedFailureNotice();
    } catch (_) { if (this.active) { this.notice = this.label('draft_load_error'); } }
  }
  private savedFailureNotice(): string {
    const diagnostic = sendFailureDiagnostic(this.draft);
    if (!diagnostic || (this.draft.state !== 'draft' && this.draft.state !== 'unconfirmed')) { return ''; }
    // Unconfirmed drafts already show the persistent no-resend explanation.
    return this.draft.state === 'unconfirmed' ? diagnostic :
      `${this.label(sendFailureLabel(this.draft.state, this.draft.failureCode))} (${diagnostic})`;
  }
  private async loadRecipients(): Promise<void> {
    const accountId = this.account.id;
    try {
      const history = await this.store.recipients(accountId);
      if (this.active && this.account.id === accountId) { this.recipientHistory = history; }
    } catch (_) { /* Composing stays available if optional local history cannot be read. */ }
  }
  private addressValue(field: string): string { return field === 'to' ? this.draft.to : field === 'cc' ? this.draft.cc : this.draft.bcc; }
  private addressFocus(field: string): void { this.recipientField = field; this.recipientCaret = this.addressValue(field).length; }
  private addressChanged(field: string, value: string): void {
    if (field === 'to') { this.draft.to = value; }
    else if (field === 'cc') { this.draft.cc = value; }
    else { this.draft.bcc = value; }
    this.recipientField = field; this.recipientCaret = value.length; this.save();
  }
  private suggestions(field: string): RecipientRecord[] {
    if (this.recipientField !== field || !this.editable()) { return []; }
    const other = field === 'to' ? [this.draft.cc, this.draft.bcc] : field === 'cc' ? [this.draft.to, this.draft.bcc] : [this.draft.to, this.draft.cc];
    return recipientSuggestions(this.recipientHistory, this.addressValue(field), this.recipientCaret, other);
  }
  private chooseRecipient(field: string, email: string): void {
    const original = this.addressValue(field), token = recipientToken(original, this.recipientCaret);
    const completed = completeRecipient(original, this.recipientCaret, email);
    this.addressChanged(field, completed); this.recipientField = '';
    const controller = field === 'to' ? this.toController : field === 'cc' ? this.ccController : this.bccController;
    controller.caretPosition(completed.length - (original.length - token.end));
  }

  @Builder
  private addressSuggestions(field: string) {
    if (this.suggestions(field).length > 0) {
      Column() {
        ForEach(this.suggestions(field), (recipient: RecipientRecord) => {
          Button({ type: ButtonType.Normal }) {
            Column({ space: 2 }) {
              if (recipient.name) {
                Text(recipient.name).fontSize(15).fontColor($r('app.color.mail_text_primary')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              Text(recipient.email).fontSize(recipient.name ? 13 : 15)
                .fontColor(recipient.name ? $r('app.color.mail_text_secondary') : $r('app.color.mail_text_primary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 56, right: 12, top: 8, bottom: 8 })
          }.id(`recipient-${field}-${recipient.email.toLowerCase()}`).width('100%').constraintSize({ minHeight: 44 })
            .padding(0).borderRadius(0).backgroundColor($r('app.color.mail_surface')).focusable(false)
            .accessibilityText(recipient.name ? `${recipient.name}, ${recipient.email}` : recipient.email)
            .onClick(() => this.chooseRecipient(field, recipient.email))
          Divider().color($r('app.color.mail_divider'))
        }, (recipient: RecipientRecord) => recipient.email.toLowerCase())
      }.id(`recipient-suggestions-${field}`).width('100%')
    }
  }
  private async newDraft(): Promise<OutgoingDraft> {
    const value = new OutgoingDraft(); value.id = util.generateRandomUUID(); value.date = Date.now();
    await this.store.prepareNewOutgoing(this.account.id, value);
    this.initialText = value.text;
    return value;
  }
  private async save(): Promise<void> {
    try { await this.store.saveOutgoing(this.account.id, this.draft); this.saveFailed = false; }
    catch (_) { this.saveFailed = true; }
  }
  private settings(): SmtpSettings {
    const value = new SmtpSettings();
    if (!/^[A-Za-z0-9.-]+$/.test(this.host.trim()) || !/^\d+$/.test(this.port) || Number(this.port) < 1 || Number(this.port) > 65535) {
      throw new SmtpError('unsafeEndpoint');
    }
    value.endpoint = `${this.tls ? 'smtps' : 'smtp'}://${this.host.trim()}:${Number(this.port)}`;
    value.username = this.username.trim(); value.password = this.password; return value;
  }
  private async saveSettings(): Promise<void> {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const settings = this.settings();
      if (!settings.username || (!settings.password && this.account.authentication !== 'oauth')) { throw new Error('Missing login'); }
      await this.store.saveSmtp(this.account, settings);
      if (this.active) {
        this.setup = false; this.notice = '';
        this.getUIContext().getPromptAction().showToast({ message: this.label('smtp_saved') });
      }
    } catch (_) {
      if (this.active) { this.notice = this.label('smtp_settings_error'); }
      else { BackgroundSend.publish(this.account.id, 'smtp_settings_error'); }
    }
    finally { this.busy = false; }
  }
  private editable(): boolean { return this.ready && !this.busy && this.draft.state === 'draft' && !BackgroundSend.isSending(this.account.id); }
  private async send(): Promise<void> {
    if (!this.editable()) { return; }
    if (!this.host || !this.username || (!this.password && this.account.authentication !== 'oauth')) { this.setup = true; return; }
    this.busy = true; this.notice = '';
    this.draft.failureStage = ''; this.draft.failureCode = '';
    try {
      const settings = this.settings();
      await BackgroundSend.queue(this.account, this.store, this.draft, settings);
      this.draft.state = 'sending';
      if (this.active) { this.onQueued(); }
    } catch (error) {
      const code = (error as SmtpError)?.code;
      const notice = code === 'alreadySending' ? 'send_in_progress' : code === 'alreadySent' ? 'sent' :
        !code ? 'draft_save_error' : sendFailureLabel('draft', code);
      if (code !== 'alreadySending' && code !== 'alreadySent') {
        setSendFailure(this.draft, 'preflight', code);
        await this.save();
      }
      const diagnostic = sendFailureDiagnostic(this.draft);
      if (this.active) { this.notice = `${this.label(notice)}${diagnostic ? ` (${diagnostic})` : ''}`; }
      else { BackgroundSend.publish(this.account.id, notice, this.draft.failureStage, this.draft.failureCode); }
    } finally { this.busy = false; }
  }
  private cancel(): void {
    // Navigation never waits on validation, credential renewal or submission.
    // The submission job owns its snapshot once Send has been pressed.
    if (this.busy || BackgroundSend.isSending(this.account.id)) { this.onClose(false); return; }
    if (this.draft.to || this.draft.cc || this.draft.bcc || this.draft.subject || (this.draft.text && this.draft.text !== this.initialText) || this.draft.forwardHtml) {
      this.getUIContext().showAlertDialog({ title: this.label('keep_draft'), message: this.label('keep_draft_detail'),
        primaryButton: { value: this.label('save_draft'), action: async () => { await this.save(); if (!this.saveFailed) { this.onClose(false); } } },
        secondaryButton: { value: this.label('discard'), action: async () => {
          try { await this.store.clearOutgoing(this.account.id); this.onClose(false); }
          catch (_) { this.notice = this.label('discard_error'); }
        } }
      });
    } else { this.onClose(false); }
  }

  @Builder
  private settingsSheet() {
    Scroll() {
      Column({ space: 16 }) {
        Text(this.label('outgoing_server')).fontSize(22).fontWeight(FontWeight.Medium).width('100%')
        Text(this.label('smtp_setup_help')).fontSize(14)
        TextInput({ text: this.host, placeholder: this.label('smtp_server') }).id('smtp-host').enabled(!this.busy).onChange(value => this.host = value)
        Select([{ value: 'STARTTLS' }, { value: 'SSL/TLS' }]).selected(this.tls ? 1 : 0).value(this.tls ? 'SSL/TLS' : 'STARTTLS')
          .enabled(!this.busy).onSelect(index => { this.tls = index === 1; this.port = this.tls ? '465' : '587'; })
        TextInput({ text: this.port, placeholder: this.label('port') }).id('smtp-port').type(InputType.Number)
          .enabled(!this.busy).onChange(value => this.port = value)
        TextInput({ text: this.username, placeholder: this.label('smtp_username') }).id('smtp-username').enableAutoFill(false)
          .enabled(!this.busy).onChange(value => this.username = value)
        if (this.account.authentication !== 'oauth') {
          TextInput({ text: this.password, placeholder: this.label('smtp_password') }).id('smtp-password').type(InputType.Password).enableAutoFill(false)
            .enabled(!this.busy).onChange(value => this.password = value)
        }
        if (this.notice) { Text(this.notice).fontSize(14).width('100%') }
        Button(this.label('save')).id('save-smtp').width('100%').enabled(!this.busy).onClick(() => this.saveSettings())
      }.padding(24).width('100%').constraintSize({ maxWidth: 640 })
    }.width('100%').height('100%').align(Alignment.Top)
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Button(this.label('cancel')).id('cancel-compose').buttonStyle(ButtonStyleMode.NORMAL).fontSize(17)
          .height(44).padding({ left: this.compact ? 16 : 15, right: this.compact ? 16 : 15 })
          .fontColor($r('app.color.mail_text_primary')).backgroundColor($r('app.color.mail_surface'))
          .onClick(() => this.cancel())
        if (this.compact) { Blank() } else {
        Text(this.label('new_message')).fontSize(16).fontWeight(600).layoutWeight(1).textAlign(TextAlign.Center)
          .fontColor($r('app.color.mail_text_primary'))
          .maxLines(1).minFontSize(14).maxFontSize(16)
        }
        Button({ type: ButtonType.Circle }) { Text('⋯').fontSize(24).fontColor($r('app.color.mail_text_primary')) }
          .id('compose-more').width(40).height(44).backgroundColor(Color.Transparent).accessibilityText(this.label('more'))
          .enabled(this.ready && !this.busy).bindMenu([{ value: this.label('outgoing_server'), action: () => { this.notice = ''; this.setup = true; } }])
        if (this.busy) { LoadingProgress().width(40).height(40) }
        else {
          Button(this.label('send')).id('send-mail').buttonStyle(ButtonStyleMode.EMPHASIZED).fontSize(17)
            .height(44).padding({ left: this.compact ? 16 : 15, right: this.compact ? 16 : 15 })
            .backgroundColor($r('app.color.mail_primary_button')).fontColor(Color.White)
            .enabled(this.editable() && (this.draft.to.trim() !== '' || this.draft.cc.trim() !== '' || this.draft.bcc.trim() !== ''))
            .onClick(() => this.send())
        }
      }.width('100%').constraintSize({ maxWidth: 760 }).padding({ left: this.compact ? 16 : 20, right: this.compact ? 16 : 20,
        top: this.compact ? 4 : this.tablet ? 14 : 8, bottom: this.compact ? 4 : this.tablet ? 14 : 8 })
      Divider().color($r('app.color.mail_divider'))
      Scroll() {
      Column() {
        if (this.draft.state === 'unconfirmed') {
          Text(this.label('delivery_uncertain')).id('send-unconfirmed').fontSize(14).padding({ top: 12 })
          Button(this.label('allow_retry')).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => this.getUIContext().showAlertDialog({
            title: this.label('send_again'), message: this.label('send_again_detail'),
            primaryButton: { value: this.label('cancel'), action: () => {} },
            secondaryButton: { value: this.label('enable_retry'), action: () => { this.draft.state = 'draft'; this.save(); } }
          }))
        }
        if (this.notice) { Text(this.notice).id('send-notice').fontSize(14).width('100%').padding({ top: 12, bottom: 12 }) }
        if (this.saveFailed) { Text(this.label('draft_save_error')).id('draft-save-error').fontSize(14).padding(8) }
        Row({ space: 12 }) {
          Text(this.label('to_field')).fontSize(17).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 44 }).maxLines(1)
          TextInput({ text: this.draft.to, controller: this.toController }).id('compose-to').type(InputType.Normal).enableAutoFill(false).layoutWeight(1)
            .fontSize(17).fontColor($r('app.color.mail_text_primary')).height(48).backgroundColor(Color.Transparent).borderRadius(0).padding(0)
            .enabled(this.editable()).onChange(value => this.addressChanged('to', value)).onFocus(() => this.addressFocus('to'))
            .onTextSelectionChange((_, end) => { if (this.recipientField === 'to') { this.recipientCaret = end; } })
        }.width('100%')
        Divider().color($r('app.color.mail_divider'))
        this.addressSuggestions('to')
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            Text(this.label('cc_bcc_fields')).fontSize(15).fontColor($r('app.color.mail_text_secondary'))
            if (!this.expandedAddresses) {
              Text(`${this.label('from_field')} ${this.draft.senderName ? `${this.draft.senderName} <${this.account.emailAddress}>` : this.account.emailAddress}`).id('compose-from-summary')
                .fontSize(15).fontColor($r('app.color.mail_text_secondary')).layoutWeight(1)
                .maxLines(1).wordBreak(WordBreak.BREAK_ALL).textOverflow({ overflow: TextOverflow.Ellipsis })
            } else { Blank() }
            SymbolGlyph(this.expandedAddresses ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
              .fontSize(16).fontColor([$r('app.color.mail_text_secondary')])
          }.width('100%')
        }.id('expand-addresses').width('100%').constraintSize({ minHeight: 48 }).padding(0)
          .backgroundColor(Color.Transparent).borderRadius(8)
          .accessibilityText(`${this.label('from_field')} ${this.account.emailAddress}. ${this.label(this.expandedAddresses ? 'hide_address_fields' : 'show_address_fields')}`)
          .onClick(() => { this.recipientField = ''; this.expandedAddresses = !this.expandedAddresses; })
        Divider().color($r('app.color.mail_divider'))
        if (this.expandedAddresses) {
          Row({ space: 12 }) {
            Text(this.label('cc_field')).fontSize(17).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 44 }).maxLines(1)
            TextInput({ text: this.draft.cc, controller: this.ccController }).id('compose-cc').type(InputType.Normal).enableAutoFill(false).layoutWeight(1)
              .fontSize(17).fontColor($r('app.color.mail_text_primary')).height(48).backgroundColor(Color.Transparent).borderRadius(0).padding(0)
              .enabled(this.editable()).onChange(value => this.addressChanged('cc', value)).onFocus(() => this.addressFocus('cc'))
              .onTextSelectionChange((_, end) => { if (this.recipientField === 'cc') { this.recipientCaret = end; } })
          }.width('100%')
          Divider().color($r('app.color.mail_divider'))
          this.addressSuggestions('cc')
          Row({ space: 12 }) {
            Text(this.label('bcc_field')).fontSize(17).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 44 }).maxLines(1)
            TextInput({ text: this.draft.bcc, controller: this.bccController }).id('compose-bcc').type(InputType.Normal).enableAutoFill(false).layoutWeight(1)
              .fontSize(17).fontColor($r('app.color.mail_text_primary')).height(48).backgroundColor(Color.Transparent).borderRadius(0).padding(0)
              .enabled(this.editable()).onChange(value => this.addressChanged('bcc', value)).onFocus(() => this.addressFocus('bcc'))
              .onTextSelectionChange((_, end) => { if (this.recipientField === 'bcc') { this.recipientCaret = end; } })
          }.width('100%')
          Divider().color($r('app.color.mail_divider'))
          this.addressSuggestions('bcc')
          Row({ space: 12 }) {
            Text(this.label('from_field')).fontSize(17).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 44 }).maxLines(1)
            Text(this.draft.senderName ? `${this.draft.senderName} <${this.account.emailAddress}>` : this.account.emailAddress).id('compose-from').fontSize(15).fontColor($r('app.color.mail_text_secondary'))
              .layoutWeight(1).wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.LocalDevice)
          }.alignItems(VerticalAlign.Top).width('100%').constraintSize({ minHeight: 48 }).padding({ top: 12, bottom: 12 })
          Divider().color($r('app.color.mail_divider'))
        }
        Row({ space: 12 }) {
          Text(`${this.label('subject')}:`).fontSize(17).fontColor($r('app.color.mail_text_secondary')).constraintSize({ minWidth: 64 }).maxLines(1)
          TextInput({ text: this.draft.subject }).id('compose-subject').maxLength(300).layoutWeight(1)
            .fontSize(17).fontColor($r('app.color.mail_text_primary')).height(48).backgroundColor(Color.Transparent).borderRadius(0).padding(0)
            .enabled(this.editable()).onChange(value => { this.draft.subject = value; this.save(); })
            .onFocus(() => this.recipientField = '')
        }.width('100%')
        Divider().color($r('app.color.mail_divider'))
        if (this.draft.forwardWarning) {
          Text(this.draft.forwardWarning.replace('Attachments are not included.', this.label('forward_attachments')).replace('Only the downloaded portion of this message is included.', this.label('forward_partial')).replace('Some original text could not be decoded.', this.label('forward_encoding'))).id('forward-warning').fontSize(14).fontColor($r('app.color.mail_text_secondary')).padding({ top: 12 })
        }
        TextArea({ text: this.draft.text, placeholder: this.draft.forwardHtml ? this.label('add_message') : '' }).id('compose-body').height(Math.max(this.compact ? 240 : this.tablet ? 390 : 320, this.viewportHeight - (this.expandedAddresses ? 408 : 260))).width('100%').maxLength(60000)
          .fontSize(17).lineHeight(27.2).fontColor($r('app.color.mail_text_primary')).backgroundColor(Color.Transparent).borderRadius(0).padding({ left: 0, right: 0, top: 20, bottom: 20 })
          .enabled(this.editable()).onChange(value => { this.draft.text = value; this.save(); })
          .onFocus(() => this.recipientField = '')
        if (this.draft.forwardHtml) {
          HtmlMail({ html: this.draft.forwardHtml, messageKey: this.draft.id,
            accountId: this.account.id, pictureCache: this.store.pictures, contentInset: 0 })
            .id('forward-preview').height(Math.max(240, this.viewportHeight / 2)).width('100%')
        }
      }.padding({ left: this.compact ? 16 : 20, right: this.compact ? 16 : 20, bottom: 20 }).width('100%')
        .constraintSize({ maxWidth: 760 }).alignItems(HorizontalAlign.Start)
      }.id('compose-scroll').width('100%').layoutWeight(1).align(Alignment.Top)
    }.id('compose-panel').width('100%').height('100%').backgroundColor($r('app.color.mail_background'))
    .onAreaChange((_, area) => { this.compact = Number(area.width) < 360; this.tablet = this.tabletLayout || Number(area.width) >= 760; this.viewportHeight = Number(area.height); })
    .bindSheet($$this.setup, this.settingsSheet, { height: SheetSize.LARGE, dragBar: true })
  }
}
