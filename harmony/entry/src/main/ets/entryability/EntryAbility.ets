/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppLanguage } from '../settings/AppLanguage';
import { MailNotificationService } from '../mail/notifications/MailNotificationService';
import { PictureCache } from '../data/PictureCache';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private notificationWant(want: Want): void {
    const accountId = want.parameters?.mailNotificationAccountId;
    if (typeof accountId === 'string' && /^[0-9a-fA-F-]{36}$/.test(accountId)) {
      AppStorage.setOrCreate('mailNotificationAccountId', accountId);
      AppStorage.setOrCreate('mailNotificationOpenRevision', (AppStorage.get<number>('mailNotificationOpenRevision') || 0) + 1);
    }
  }

  onCreate(want: Want): void {
    this.notificationWant(want);
    AppLanguage.load(this.context);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    PictureCache.setForeground(false);
    MailNotificationService.onBackground();
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      AppLanguage.refresh(this.context);
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    PictureCache.setForeground(false);
    MailNotificationService.onBackground();
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    PictureCache.setForeground(true);
    try { AppLanguage.refresh(this.context); } catch (_) {}
    MailNotificationService.onForeground(this.context);
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    PictureCache.setForeground(false);
    MailNotificationService.onBackground();
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }

  onNewWant(want: Want): void { this.notificationWant(want); }
}
