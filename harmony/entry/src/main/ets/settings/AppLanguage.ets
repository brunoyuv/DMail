// MPL-2.0: https://mozilla.org/MPL/2.0/
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { i18n } from '@kit.LocalizationKit';

export class AppLanguage {
  static choice: string = 'default';
  static locale: string = 'en';
  static load(context: common.Context): void {
    try {
      const saved = preferences.getPreferencesSync(context, { name: 'appearance' }).getSync('language', 'default');
      AppLanguage.choice = saved === 'en' || saved === 'zh-Hans' ? saved : 'default';
    } catch (_) { AppLanguage.choice = 'default'; }
  }
  static refresh(context: common.Context): void {
    const desired = AppLanguage.choice === 'default' ? i18n.System.getSystemLanguage() : AppLanguage.choice;
    // English is the complete fallback for languages we do not translate yet.
    AppLanguage.locale = desired.startsWith('zh') ? 'zh-CN' : 'en';
    context.getApplicationContext().setLanguage(AppLanguage.locale);
    AppStorage.setOrCreate('appLanguageRevision', (AppStorage.get<number>('appLanguageRevision') ?? 0) + 1);
  }
  static async set(context: common.Context, choice: string): Promise<void> {
    if (!['default', 'en', 'zh-Hans'].includes(choice)) { throw new Error('Invalid language'); }
    const store = preferences.getPreferencesSync(context, { name: 'appearance' });
    store.putSync('language', choice);
    await store.flush();
    i18n.System.setAppPreferredLanguage(choice);
    AppLanguage.choice = choice;
    AppLanguage.refresh(context);
  }
}
