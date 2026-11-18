import { workScheduler } from '@kit.BackgroundTasksKit';

const WORK_ID: number = 43871;

export async function updateSchedule(bundleName: string, enabled: boolean): Promise<void> {
  const tasks: workScheduler.WorkInfo[] = await workScheduler.obtainAllWorks();
  const existing: workScheduler.WorkInfo | undefined = tasks.find(
    (item: workScheduler.WorkInfo): boolean => item.workId === WORK_ID
  );
  if (!enabled && existing) {
    workScheduler.stopWork(existing, true);
  }
  if (enabled && !existing) {
    workScheduler.startWork({
      workId: WORK_ID,
      bundleName: bundleName,
      abilityName: 'ScreenshotSyncWork',
      networkType: workScheduler.NetworkType.NETWORK_TYPE_WIFI,
      isRepeat: true,
      repeatCycleTime: 2 * 60 * 60 * 1000,
      isPersisted: true
    });
  }
}
