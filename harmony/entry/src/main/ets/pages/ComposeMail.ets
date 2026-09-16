// MPL-2.0: https://mozilla.org/MPL/2.0/
import { PreparedMailDocument } from '../data/PreparedDocumentModel';
import { preparedMailDocument } from '../mail/html/HtmlDocument';
import { HtmlMail } from './HtmlMail';
import { DeferredSave } from './DeferredSave';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AccountStore, SavedAccount } from '../data/AccountStore';
import { OutgoingDraft, SmtpSettings, SmtpError } from '../mail/smtp/NativeSmtpClient';
import { BackgroundSend } from '../mail/smtp/BackgroundSend';
import { OutgoingAttachmentFiles } from '../mail/attachments/OutgoingAttachmentFiles';
import { OutgoingAttachment, OUTGOING_ATTACHMENT_BYTES, OUTGOING_ATTACHMENT_COUNT } from '../mail/attachments/OutgoingAttachmentModel';
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
  @State private previewing: boolean = false;
  @State private previewDocument: PreparedMailDocument | undefined = undefined;
  @State private previewBusy: boolean = false;
  private previewRevision: number = 0;
  @State private ready: boolean = false;
  @State private busy: boolean = false;
  @State private notice: string = '';
  @State private saveFailed: boolean = false;
  private attachmentRevision: number = 0;
  @State private attachmentPicking: boolean = false;
  @State private attachmentNotice: string = '';
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
  private saves: DeferredSave = new DeferredSave();
  private saveRevision: number = 0;
  private initializeRevision: number = 0;

  aboutToAppear(): void { this.active = true; this.initialize(); }
  aboutToDisappear(): void {
    this.saves.flush().catch(() => {});
    this.active = false; ++this.previewRevision; ++this.initializeRevision; this.password = '';
  }
  private sendingChanged(): void {
    if (this.active && this.draft.state === 'sending' && !BackgroundSend.isSending(this.account.id)) { this.initialize(); }
  }
  private async initialize(): Promise<void> {
    const revision = ++this.initializeRevision, account = this.account;
    ++this.previewRevision; this.previewing = false; this.previewBusy = false; this.previewDocument = undefined;
    ++this.attachmentRevision; this.attachmentPicking = false; this.attachmentNotice = '';
    this.ready = false;
    this.loadRecipients();
    try {
      const saved = await this.store.outgoing(account.id, BackgroundSend.isSending(account.id));
      if (!this.active || revision !== this.initializeRevision) { return; }
      const retained = saved && saved.state !== 'sent' && !BackgroundSend.wasAccepted(account.id, saved.id);
      const draft = retained ? saved! : await this.newDraft();
      if (!this.active || revision !== this.initializeRevision) { return; }
      const settings = await this.store.smtp(account);
      if (!this.active || revision !== this.initializeRevision) { return; }
      this.draft = draft; this.initialText = retained ? '' : draft.text;
      const match = /^(smtps?):\/\/([^/:]+):(\d+)$/.exec(settings.endpoint);
      if (match) { this.tls = match[1] === 'smtps'; this.host = match[2]; this.port = match[3]; }
      this.username = settings.username; this.password = settings.password;
      this.setup = false; this.expandedAddresses = this.draft.cc !== '' || this.draft.bcc !== ''; this.ready = true;
      this.notice = this.draft.state === 'sending' ? this.label('send_in_progress') : this.savedFailureNotice();
    } catch (_) { if (this.active && revision === this.initializeRevision) { this.notice = this.label('draft_load_error'); } }
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
    if (!this.editable()) { return; }
    if (field === 'to') { this.draft.to = value; }
    else if (field === 'cc') { this.draft.cc = value; }
    else { this.draft.bcc = value; }
    this.recipientField = field; this.recipientCaret = value.length; this.scheduleSave();
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
    return value;
  }
  private scheduleSave(): void {
    const accountId = this.account.id, draft = this.draft, store = this.store, revision = ++this.saveRevision;
    this.saves.schedule(async () => {
      try {
        await store.saveOutgoing(accountId, draft);
        if (this.active && draft === this.draft && revision === this.saveRevision) { this.saveFailed = false; }
      } catch (error) {
        if (this.active && draft === this.draft && revision === this.saveRevision) { this.saveFailed = true; }
        throw error as Error;
      }
    });
  }
  private async save(): Promise<void> {
    this.scheduleSave();
    await this.saves.flush().catch(() => {});
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
  private editable(): boolean { return this.ready && !this.busy && !this.attachmentPicking && this.draft.state === 'draft' && !BackgroundSend.isSending(this.account.id); }
  private attachmentSize(size: number): string {
    return size >= 1048576 ? `${(size / 1048576).toFixed(1)} MB` : `${Math.ceil(size / 1024)} KB`;
  }
  private async attachFiles(): Promise<void> {
    if (!this.editable() || (this.draft.attachments?.length ?? 0) >= OUTGOING_ATTACHMENT_COUNT) { return; }
    const accountId = this.account.id, draft = this.draft, attachmentRevision = ++this.attachmentRevision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const current = (): boolean => this.active && attachmentRevision === this.attachmentRevision && this.account.id === accountId && this.draft === draft && draft.state === 'draft';
    this.attachmentPicking = true; this.attachmentNotice = ''; this.recipientField = '';
    try {
      const locations = await new picker.DocumentViewPicker(context).select({ maxSelectNumber: OUTGOING_ATTACHMENT_COUNT - (draft.attachments?.length ?? 0) });
      if (!current()) { return; }
      const files = new OutgoingAttachmentFiles(context.filesDir);
      for (const uri of locations) {
        if (!current()) { return; }
        const existing = draft.attachments ?? [];
        if (existing.length >= OUTGOING_ATTACHMENT_COUNT) { throw new Error('Attachment count limit'); }
        const remaining = OUTGOING_ATTACHMENT_BYTES - existing.reduce((sum: number, item: OutgoingAttachment): number => sum + item.size, 0);
        const attachment = await files.importURI(accountId, draft.id, uri, remaining, current);
        if (!current()) { return; }
        draft.attachments = existing.concat(attachment);
        this.scheduleSave();
      }
      await this.saves.flush();
    } catch (_) { if (current()) { this.attachmentNotice = this.label('attach_file_error'); } }
    finally { if (attachmentRevision === this.attachmentRevision) { this.attachmentPicking = false; } }
  }
  private async removeAttachment(id: string): Promise<void> {
    if (!this.editable()) { return; }
    const accountId = this.account.id, draft = this.draft;
    const attachment = (draft.attachments ?? []).find((item: OutgoingAttachment): boolean => item.id === id);
    if (!attachment) { return; }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    draft.attachments = (draft.attachments ?? []).filter((item: OutgoingAttachment): boolean => item.id !== id);
    this.attachmentNotice = ''; this.scheduleSave();
    try {
      await this.saves.flush();
      // Only remove bytes once no saved draft refers to them. The captured
      // account/draft remains the owner if the user navigates while saving.
      await new OutgoingAttachmentFiles(context.filesDir).remove(accountId, draft.id, attachment);
    } catch (_) { /* Preserve the file when its metadata could not be saved. */ }
  }

  @Builder
  private composeAttachments() {
    Column({ space: 0 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.paperclip')).fontSize(20).fontColor([$r('app.color.mail_accent')])
          Text(this.label(this.attachmentPicking ? 'adding_attachments' : 'attach_files')).fontSize(15).fontColor($r('app.color.mail_accent')).layoutWeight(1)
          if ((this.draft.attachments?.length ?? 0) > 0) {
            Text(`${this.draft.attachments.length} · ${this.attachmentSize(this.draft.attachments.reduce((sum: number, item: OutgoingAttachment): number => sum + item.size, 0))}`)
              .fontSize(13).fontColor($r('app.color.mail_text_secondary'))
          }
        }.width('100%').constraintSize({ minHeight: 48 })
      }.id('attach-files').width('100%').padding(0).backgroundColor(Color.Transparent)
        .enabled(this.editable() && (this.draft.attachments?.length ?? 0) < OUTGOING_ATTACHMENT_COUNT)
        .onClick(() => this.attachFiles())
      ForEach(this.draft.attachments ?? [], (attachment: OutgoingAttachment) => {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text(attachment.name).fontSize(14).fontColor($r('app.color.mail_text_primary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.attachmentSize(attachment.size)).fontSize(12).fontColor($r('app.color.mail_text_secondary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(15).fontColor([$r('app.color.mail_text_secondary')])
          }.id(`remove-compose-attachment-${attachment.id}`).width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText(`${this.label('remove_attachment')}: ${attachment.name}`).enabled(this.editable())
            .onClick(() => this.removeAttachment(attachment.id))
        }.id(`compose-attachment-${attachment.id}`).width('100%').padding({ left: 12, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.mail_surface')).borderRadius(10).margin({ bottom: 6 })
      }, (attachment: OutgoingAttachment) => attachment.id)
      if (this.attachmentNotice) { Text(this.attachmentNotice).fontSize(13).fontColor($r('app.color.mail_text_secondary')).padding({ bottom: 8 }) }
    }.id('compose-attachments').width('100%').alignItems(HorizontalAlign.Start)
  }
  private async send(): Promise<void> {
    if (!this.editable()) { return; }
    if (!this.host || !this.username || (!this.password && this.account.authentication !== 'oauth')) { this.setup = true; return; }
    this.busy = true; this.notice = '';
    this.draft.failureStage = ''; this.draft.failureCode = '';
    try {
      const settings = this.settings();
      await this.saves.flush();
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
  private async preview(): Promise<void> {
    if (!this.ready || this.busy || this.previewBusy) { return; }
    const revision = ++this.previewRevision, accountId = this.account.id, draftId = this.draft.id;
    const text = this.draft.text, forward = this.draft.forwardHtml;
    this.previewBusy = true; this.notice = '';
    try {
      const options = await this.store.mathSettings(accountId);
      const renderer = await import('../mail/math/MarkdownPreview');
      const math = await import('../mail/math/MarkdownMath');
      const html = await renderer.markdownPreview(text, options.renderer || 'mathml');
      if (!this.active || revision !== this.previewRevision || accountId !== this.account.id || draftId !== this.draft.id ||
        text !== this.draft.text || forward !== this.draft.forwardHtml) { return; }
      this.previewDocument = { version: 1, messageKey: draftId + ':preview:' + revision, bodySavedAt: this.draft.date,
        savedAt: Date.now(), html: math.mathFontDocument(preparedMailDocument(html + (forward ? '<br>' + forward : ''), false, 20), options.renderer || 'mathml'), pictures: [] };
      this.previewing = true;
    } catch (_) { if (this.active && revision === this.previewRevision) { this.notice = this.label('math_render_error'); } }
    finally { if (this.active && revision === this.previewRevision) { this.previewBusy = false; } }
  }
  @Builder
  private previewSheet() {
    Column({ space: 12 }) {
      Button(this.label('math_edit')).id('close-compose-preview').onClick(() => this.previewing = false)
      Text(this.label('math_preview_help')).fontSize(14).padding({ left: 20, right: 20 })
      if (this.previewDocument) {
        HtmlMail({ savedDocument: this.previewDocument, html: '', messageKey: this.previewDocument.messageKey,
          accountId: this.account.id, readerVisible: this.previewing }).id('compose-preview').width('100%').layoutWeight(1)
      }
    }.width('100%').height('100%').padding({ top: 12 })
  }
  private cancel(): void {
    // Navigation never waits on validation, credential renewal or submission.
    // The submission job owns its snapshot once Send has been pressed.
    if (this.busy || this.attachmentPicking || BackgroundSend.isSending(this.account.id)) { this.onClose(false); return; }
    const accountId = this.account.id, draft = this.draft;
    if (this.draft.to || this.draft.cc || this.draft.bcc || this.draft.subject || (this.draft.text && this.draft.text !== this.initialText) || this.draft.forwardHtml || (this.draft.attachments?.length ?? 0) > 0) {
      this.getUIContext().showAlertDialog({ title: this.label('keep_draft'), message: this.label('keep_draft_detail'),
        primaryButton: { value: this.label('save_draft'), action: async () => { await this.save(); if (!this.saveFailed) { this.onClose(false); } } },
        secondaryButton: { value: this.label('discard'), action: async () => {
          if (!this.active || !this.editable() || this.account.id !== accountId || this.draft !== draft) { return; }
          this.busy = true;
          this.saves.cancel();
          try { await this.store.clearOutgoing(accountId, draft.id); if (this.active) { this.onClose(false); } }
          catch (_) { if (this.active) { this.busy = false; this.notice = this.label('discard_error'); } }
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
          .enabled(this.ready && !this.busy && !this.previewBusy).bindMenu([{ value: this.label('math_preview'), action: () => this.preview() }, { value: this.label('outgoing_server'), action: () => { this.notice = ''; this.setup = true; } }])
          .bindSheet($$this.previewing, this.previewSheet, { height: SheetSize.LARGE, dragBar: true })
        if (this.busy || this.previewBusy) { LoadingProgress().width(40).height(40) }
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
            .enabled(this.editable()).onChange(value => { if (this.editable()) { this.draft.subject = value; this.scheduleSave(); } })
            .onFocus(() => this.recipientField = '')
        }.width('100%')
        Divider().color($r('app.color.mail_divider'))
        if (this.draft.forwardWarning) {
          Text(this.draft.forwardWarning.replace('Attachments are not included.', this.label('forward_attachments')).replace('Only the downloaded portion of this message is included.', this.label('forward_partial')).replace('Some original text could not be decoded.', this.label('forward_encoding'))).id('forward-warning').fontSize(14).fontColor($r('app.color.mail_text_secondary')).padding({ top: 12 })
        }
        this.composeAttachments()
        TextArea({ text: this.draft.text, placeholder: this.draft.forwardHtml ? this.label('add_message') : '' }).id('compose-body').height(Math.max(this.compact ? 240 : this.tablet ? 390 : 320, this.viewportHeight - (this.expandedAddresses ? 408 : 260))).width('100%').maxLength(60000)
          .fontSize(17).lineHeight(27.2).fontColor($r('app.color.mail_text_primary')).backgroundColor(Color.Transparent).borderRadius(0).padding({ left: 0, right: 0, top: 20, bottom: 20 })
          .enabled(this.editable()).onChange(value => { if (this.editable()) { this.draft.text = value; this.scheduleSave(); } })
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
