import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { startSyncSession, SYNC_SESSION_START } from '../sync/Pairing';

export default class EntryAbility extends UIAbility {
  onCreate(): void {
    const startedMs: number = Date.now();
    AppStorage.setOrCreate<number>(SYNC_SESSION_START, startedMs);
    try {
      startSyncSession(this.context, startedMs);
    } catch (_error) {
      // The page can show the settings error and keeps uploads disabled for this session.
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index');
  }

  onForeground(): void {
    AppStorage.setOrCreate<boolean>('syncForeground', true);
  }

  onBackground(): void {
    AppStorage.setOrCreate<boolean>('syncForeground', false);
  }
}
