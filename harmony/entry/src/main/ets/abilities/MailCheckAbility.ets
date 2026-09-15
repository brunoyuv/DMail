// MPL-2.0: https://mozilla.org/MPL/2.0/
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { MailNotificationService } from '../mail/notifications/MailNotificationService';

export default class MailCheckAbility extends WorkSchedulerExtensionAbility {
  private generation: number = 0;
  onWorkStart(work: workScheduler.WorkInfo): void {
    const generation = ++this.generation;
    this.check(work, generation);
  }
  private async check(work: workScheduler.WorkInfo, generation: number): Promise<void> {
    try { await MailNotificationService.run(this.context, true, () => generation !== this.generation); }
    catch (_) { /* A later scheduled check can recover; no provider details are logged. */ }
    finally {
      // An older completion must not stop a newer invocation of the same job.
      if (generation === this.generation) { try { workScheduler.stopWork(work, false); } catch (_) {} }
    }
  }
  onWorkStop(_work: workScheduler.WorkInfo): void { ++this.generation; }
}
