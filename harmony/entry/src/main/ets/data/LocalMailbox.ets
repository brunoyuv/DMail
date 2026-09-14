// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Mail, MailSnapshot, validSnapshot } from '../model/Mail';
import { sampleMailbox } from '../model/SampleMail';

// Preview storage only. Live accounts will use ArkData RDB and secure credentials.
export class LocalMailbox {
  private storage?: preferences.Preferences;
  private pending: Promise<void> = Promise.resolve();

  async load(context: common.UIAbilityContext): Promise<Mail[]> {
    let raw: preferences.ValueType;
    try {
      this.storage = await preferences.getPreferences(context, { name: 'mail_preview_v1' });
      raw = await this.storage.get('snapshot', '');
    } catch (_) {
      throw new Error('Mailbox storage is unavailable');
    }
    if (typeof raw !== 'string') {
      throw new Error('Invalid mailbox storage');
    }
    if (raw === '') {
      const messages = sampleMailbox();
      await this.save(messages);
      return messages;
    }
    const snapshot = JSON.parse(raw) as MailSnapshot;
    if (!validSnapshot(snapshot)) {
      throw new Error('Mailbox data could not be read');
    }
    return snapshot.messages;
  }

  save(messages: Mail[]): Promise<void> {
    const snapshot = new MailSnapshot();
    snapshot.messages = messages;
    const serialized = JSON.stringify(snapshot);
    // Queue immutable snapshots so rapid edits cannot overwrite newer drafts.
    const operation = this.pending.catch(() => {}).then(async () => {
      if (!this.storage) {
        throw new Error('Mailbox is not ready');
      }
      await this.storage.put('snapshot', serialized);
      await this.storage.flush();
    });
    this.pending = operation;
    return operation;
  }
}
