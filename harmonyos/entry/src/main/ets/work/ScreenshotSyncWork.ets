import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { loadPairing, Pairing } from '../sync/Pairing';
import { isCurrentSync, syncScreenshots, SyncCancellation } from '../sync/ScreenshotSync';
import { scheduledWorkId } from './Schedule';

export default class ScreenshotSyncWork extends WorkSchedulerExtensionAbility {
  private activeSync: SyncCancellation | undefined;
  private activeWorkId: number | undefined;

  onWorkStart(work: workScheduler.WorkInfo): void {
    try {
      const pairing: Pairing | undefined = loadPairing(this.context);
      if (!pairing?.enabled || pairing.sessionStartedMs === undefined ||
        work.workId !== scheduledWorkId(pairing.revision)) {
        workScheduler.stopWork(work, true);
        return;
      }
      this.activeSync?.stop();
      const cancellation = new SyncCancellation();
      this.activeSync = cancellation;
      this.activeWorkId = work.workId;
      this.run(work, pairing, cancellation);
    } catch (_error) {
      // The OS will retire an invocation whose settings cannot be read.
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    if (this.activeWorkId === work.workId) {
      this.activeSync?.stop();
      this.activeSync = undefined;
      this.activeWorkId = undefined;
    }
  }

  private async run(work: workScheduler.WorkInfo, pairing: Pairing, cancellation: SyncCancellation): Promise<void> {
    const deadline: number = Date.now() + 90_000;
    // The UI and the extension can run in separate processes.
    const timer: number = setInterval((): void => {
      try {
        if (Date.now() >= deadline || !isCurrentSync(this.context, pairing)) {
          cancellation.stop();
        }
      } catch (_error) {
        cancellation.stop();
      }
    }, 500);
    try {
      await syncScreenshots(this.context, pairing, cancellation);
    } catch (_error) {
      // Items without a successful Mac acknowledgement are retried on the next run.
    } finally {
      clearInterval(timer);
      if (this.activeSync === cancellation) {
        this.activeSync = undefined;
        this.activeWorkId = undefined;
        try {
          workScheduler.stopWork(work, false);
        } catch (_error) {
          // The OS may already have stopped this invocation.
        }
      }
    }
  }
}
