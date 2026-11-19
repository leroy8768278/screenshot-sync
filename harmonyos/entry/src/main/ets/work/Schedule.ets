import { workScheduler } from '@kit.BackgroundTasksKit';

const LEGACY_WORK_ID: number = 43871;
const ABILITY_NAME: string = 'ScreenshotSyncWork';

export function scheduledWorkId(revision: number): number {
  // Each settings revision has its own ID so a delayed stop cannot cancel its replacement.
  return LEGACY_WORK_ID + (revision % 1_000_000_000);
}

export async function updateSchedule(bundleName: string, revision: number | undefined): Promise<void> {
  const workId: number | undefined = revision === undefined ? undefined : scheduledWorkId(revision);
  const tasks: workScheduler.WorkInfo[] = await workScheduler.obtainAllWorks();
  const syncTasks: workScheduler.WorkInfo[] = tasks.filter(
    (item: workScheduler.WorkInfo): boolean => item.abilityName === ABILITY_NAME
  );
  for (const task of syncTasks) {
    if (task.workId !== workId) {
      workScheduler.stopWork(task, true);
    }
  }
  if (workId !== undefined && !syncTasks.some((task: workScheduler.WorkInfo): boolean => task.workId === workId)) {
    workScheduler.startWork({
      workId: workId,
      bundleName: bundleName,
      abilityName: ABILITY_NAME,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_WIFI,
      isRepeat: true,
      repeatCycleTime: 2 * 60 * 60 * 1000,
      isPersisted: true
    });
  }
}
