import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { loadPairing, Pairing } from '../sync/Pairing';
import { syncScreenshots } from '../sync/ScreenshotSync';

export default class ScreenshotSyncWork extends WorkSchedulerExtensionAbility {
  private generation: number = 0;

  onWorkStart(work: workScheduler.WorkInfo): void {
    const generation: number = ++this.generation;
    this.run(work, generation);
  }

  onWorkStop(_work: workScheduler.WorkInfo): void {
    this.generation++;
  }

  private async run(work: workScheduler.WorkInfo, generation: number): Promise<void> {
    const deadline: number = Date.now() + 90_000;
    try {
      const pairing: Pairing | undefined = loadPairing(this.context);
      if (pairing?.enabled) {
        await syncScreenshots(this.context, pairing,
          (): boolean => this.generation === generation && Date.now() < deadline);
      }
    } catch (_error) {
      // Items without a successful Mac acknowledgement are retried on the next run.
    } finally {
      if (this.generation === generation) {
        try {
          workScheduler.stopWork(work, false);
        } catch (_error) {
          // The OS may already have stopped this invocation.
        }
      }
    }
  }
}
