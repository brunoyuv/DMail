// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AccountStore } from '../../../main/ets/data/AccountStore';

export default class AccountTestAbility extends UIAbility {
  private stageCreated: (stage: window.WindowStage) => void = () => {};
  private stageReady: Promise<window.WindowStage> = new Promise((resolve) => { this.stageCreated = resolve; });
  onWindowStageCreate(stage: window.WindowStage): void { this.stageCreated(stage); }

  // The runner chooses whether to clear the fixture after the actual ability
  // context and window are ready. This avoids startup/Want lifecycle races.
  async showFixture(reset: boolean): Promise<void> {
    const stage = await this.stageReady;
    const store = new AccountStore('thunderbird_ui_test.db');
    await store.open(this.context);
    try {
      if (reset) { for (const account of await store.list()) { await store.remove(account.id); } }
    } finally { await store.close(); }
    await stage.loadContent('pages/AccountFixture');
  }
}
