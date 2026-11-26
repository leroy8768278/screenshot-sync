import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { clearPairing, createPairing, loadPairing, Pairing, savePairing, withSyncEnabled } from '../sync/Pairing';
import { ManualResult, SelectedMedia, selectMedia, sendSelection } from '../sync/ManualSync';
import { isPairingCode, PairingTarget, parseReceiverHost, RECEIVER_PORT } from '../sync/Protocol';
import { MacProfile, familyName, macArtwork, macDisplayName } from '../sync/MacProfile';
import { findVerifiedHost, Receiver } from '../sync/Receiver';
import { scanPairing } from '../sync/ScanPairing';
import { GALLERY_PERMISSION, galleryAllowed, syncScreenshots, SyncCancellation, SyncResult } from '../sync/ScreenshotSync';
import { updateSchedule } from '../work/Schedule';

import { clearRecentTransfers, Delivery, lastDelivery, recentTransfers } from '../sync/RecentTransfers';
import { chatSize } from '../sync/ChatTypes';
import { ChatSession } from '../sync/ChatSession';
import { ChatEntry, ChatPage } from './ChatPage';

const PINE: string = '#145848';
const MIST: string = '#CCE2D7';
const HOST_INPUT_ID: string = 'receiver-host-input';
const TOKEN_INPUT_ID: string = 'receiver-token-input';
const CHAT_ROUTE: string = 'conversation';

function versionLabel(): string {
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.versionName ? `  v${info.versionName}` : '';
  } catch (_error) {
    return '';
  }
}

@Entry
@Component
struct Index {
  private readonly pathStack: NavPathStack = new NavPathStack();
  @StorageProp('syncForeground') @Watch('foregroundChanged') private foreground: boolean = false;
  @State private host: string = '';
  @State private token: string = '';
  @State private syncEnabled: boolean = false;
  @State private macUnreachable: boolean = false;
  @State private hasPairing: boolean = false;
  @State private activeHost: string = '';
  @State private mac: MacProfile = new MacProfile();
  @State private chat: ChatSession | undefined = undefined;
  @State private cutoffLabel: string = '';
  @State private showSettings: boolean = false;
  @State private galleryGranted: boolean = false;
  @State private changingSettings: boolean = false;
  @State private pairingStatus: string = '';
  @State private uploading: boolean = false;
  @State private status: string = '等待配对';
  @State private scheduleStatus: string = '';
  @State private recent: Delivery[] = [];
  @State private lastReceiptAt: number = 0;
  @State private reviewing: boolean = false;
  @State private selecting: boolean = false;
  @State private selection: SelectedMedia[] = [];
  @State private manualSending: boolean = false;
  @State private manualStatus: string = '';

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private pairing: Pairing | undefined;
  private readonly version: string = versionLabel();
  private helper: photoAccessHelper.PhotoAccessHelper | undefined;
  private interval: number = -1;
  private scanAgain: boolean = false;
  private backgroundDelayId: number | undefined;
  private activeSync: SyncCancellation | undefined;
  private activeManual: SyncCancellation | undefined;
  private manualTarget: Pairing | undefined;
  private scheduleUpdate: Promise<void> = Promise.resolve();
  private pageReady: boolean = false;

  private onPhotoChange = (change: photoAccessHelper.PhotoAssetChangeInfos): void => {
    if (change.isForRecheck || !change.assetChangeDatas || change.assetChangeDatas.some(
      (asset: photoAccessHelper.PhotoAssetChangeData): boolean =>
        asset.assetAfterChange?.mediaType === photoAccessHelper.PhotoType.IMAGE
    )) {
      this.sync(true);
    }
  };

  aboutToAppear(): void {
    this.pageReady = true;
    try {
      this.pairing = loadPairing(this.getContext());
      if (this.pairing) {
        this.host = this.pairing.host;
        this.token = this.pairing.token;
        this.applyPairing(this.pairing);
        this.status = this.syncEnabled ? '等待同步' : '同步已停止';
      }
      this.foregroundChanged();
    } catch (_error) {
      this.status = '无法读取配对设置，请重新配对';
    }
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.chat?.close();
    this.stopListening();
    this.activeManual?.stop();
    this.activeManual = undefined;
    this.manualSending = false;
    this.clearSelection();
  }

  private applyPairing(pairing: Pairing): void {
    this.pairing = pairing;
    this.hasPairing = pairing.pairedAfterMs !== undefined;
    this.syncEnabled = this.hasPairing && pairing.enabled;
    this.activeHost = pairing.host;
    this.mac = pairing.mac ?? new MacProfile();
    this.reloadRecent();
    this.updateChat(pairing);
    if (pairing.pairedAfterMs !== undefined) {
      const date = new Date(pairing.pairedAfterMs);
      this.cutoffLabel = date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
    } else {
      this.cutoffLabel = '';
    }
  }

  private reloadRecent(): void {
    const pairing = this.hasPairing ? this.pairing : undefined;
    this.recent = pairing ? recentTransfers(this.getContext(), pairing) : [];
    this.lastReceiptAt = pairing ? lastDelivery(this.getContext(), pairing, this.recent) : 0;
  }

  private confirmClearRecent(): void {
    const paired = this.pairing;
    if (!paired || !this.recent.length) { return; }
    const visible = this.recent.slice();
    this.getUIContext().showAlertDialog({
      title: '清除最近传输记录？',
      message: '清除本机上「' + macDisplayName(this.mac) + '」当前显示的传输记录和缩略图。手机与 Mac 上的原文件将保留。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '清除', action: () => {
        if (this.pairing?.token !== paired.token) { return; }
        if (!clearRecentTransfers(this.getContext(), paired, visible)) {
          this.getUIContext().getPromptAction().showToast({ message: '未能清除全部记录，请重试。' });
        }
        this.reloadRecent();
      } }
    });
  }

  private deliveryTime(time: number): string {
    const date = new Date(time);
    const clock = date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
    return date.toLocaleDateString() === new Date().toLocaleDateString() ? clock : date.toLocaleDateString() + ' ' + clock;
  }

  private receiverDetails(): string {
    const endpoint = `${this.activeHost}:${RECEIVER_PORT}`;
    const family = familyName(this.mac.family);
    return family !== 'Mac' && macDisplayName(this.mac).toLowerCase() !== family.toLowerCase() ?
      `${family} · ${endpoint}` : endpoint;
  }

  private updateChat(pairing: Pairing | undefined): void {
    const room = pairing && pairing.pairedAfterMs !== undefined ? pairing.destination + ':' + pairing.host : undefined;
    if (this.chat?.room === room) { return; }
    this.pathStack.clear();
    this.chat?.close();
    this.chat = room ? new ChatSession(this.getContext(), room) : undefined;
    this.chat?.setForeground(this.foreground);
  }

  private foregroundChanged(): void {
    if (!this.pageReady) {
      return;
    }
    this.chat?.setForeground(this.foreground);
    if (!this.foreground) {
      // Keep the observer available for notifications delivered before the process is suspended.
      this.stopForegroundPolling();
      return;
    }
    this.refreshPermission();
    const saved: Pairing | undefined = this.pairing;
    if (saved && saved.pairedAfterMs === undefined) {
      this.connect(false, saved);
      return;
    }
    if (saved) {
      this.reloadRecent();
      this.refreshMac(saved);
    }
    this.startListening();
    if (this.hasPairing) {
      this.refreshSchedule();
    }
    if (this.syncEnabled) {
      this.sync();
    }
  }

  private async refreshMac(pairing: Pairing): Promise<void> {
    let receiver: Receiver | undefined;
    try {
      receiver = new Receiver(pairing.host, pairing.token);
      const mac = await receiver.verify();
      if (!this.pageReady || this.changingSettings || this.pairing !== pairing) { return; }
      this.macUnreachable = false;
      if (pairing.mac?.name === mac.name && pairing.mac?.family === mac.family) {
        return;
      }
      const current = loadPairing(this.getContext());
      if (!current || current.revision !== pairing.revision || current.destination !== pairing.destination) {
        return;
      }
      current.mac = mac;
      savePairing(this.getContext(), current);
      this.pairing = current;
      this.mac = mac;
    } catch (_error) {
      if (this.pageReady && !this.changingSettings && this.pairing === pairing) {
        this.macUnreachable = true;
      }
    } finally {
      receiver?.close();
    }
  }

  private refreshPermission(): void {
    try {
      this.galleryGranted = galleryAllowed(this.getContext());
    } catch (_error) {
      this.galleryGranted = false;
    }
  }

  private startListening(): void {
    if (!this.foreground || !this.syncEnabled || !this.galleryGranted || this.pairing?.pairedAfterMs === undefined) {
      return;
    }
    if (this.interval === -1) {
      this.interval = setInterval((): void => {
        this.sync();
      }, 30_000);
    }
    if (this.helper) {
      return;
    }
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.getContext());
      helper.on('photoChange', this.onPhotoChange);
      this.helper = helper;
    } catch (_error) {
      // The periodic foreground scan also covers missed photo change notifications.
    }
  }

  private stopForegroundPolling(): void {
    if (this.interval !== -1) {
      clearInterval(this.interval);
      this.interval = -1;
    }
  }

  private prepareBackgroundContinuation(cancellation: SyncCancellation): void {
    if (!this.foreground || this.activeSync !== cancellation || this.backgroundDelayId !== undefined) {
      return;
    }
    try {
      const delay = backgroundTaskManager.requestSuspendDelay('完成正在发送的截图', (): void => {
        if (this.activeSync === cancellation && this.backgroundDelayId === delay.requestId) {
          this.releaseBackgroundDelay();
          if (!this.foreground) {
            this.scanAgain = false;
            cancellation.stop();
          }
        }
      });
      this.backgroundDelayId = delay.requestId;
    } catch (_error) {
      // The transfer can proceed while the system still allows execution.
    }
  }

  private releaseBackgroundDelay(): void {
    const id = this.backgroundDelayId;
    if (id === undefined) {
      return;
    }
    this.backgroundDelayId = undefined;
    try {
      backgroundTaskManager.cancelSuspendDelay(id);
    } catch (_error) {
      // The system may already have ended the transient task.
    }
  }

  private stopListening(): void {
    this.activeSync?.stop();
    this.activeSync = undefined;
    this.uploading = false;
    this.scanAgain = false;
    this.releaseBackgroundDelay();
    this.stopForegroundPolling();
    try {
      this.helper?.off('photoChange', this.onPhotoChange);
    } catch (_error) {
      // Gallery access may have been revoked while observing.
    }
    this.helper = undefined;
  }

  private async authorizeGallery(): Promise<void> {
    this.refreshPermission();
    if (this.galleryGranted) {
      return;
    }
    const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    const context: common.UIAbilityContext = this.getContext();
    const result = await manager.requestPermissionsFromUser(context, [GALLERY_PERMISSION]);
    if (result.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED &&
      result.dialogShownResults?.[0] === false) {
      await manager.requestPermissionOnSetting(context, [GALLERY_PERMISSION]);
    }
    this.refreshPermission();
    if (!this.galleryGranted) {
      throw new Error('请在系统设置中允许访问相册，然后重试');
    }
  }

  private async grantGalleryAccess(): Promise<void> {
    if (this.changingSettings) {
      return;
    }
    this.changingSettings = true;
    try {
      await this.authorizeGallery();
      await this.refreshSchedule();
      this.startListening();
    } catch (_error) {
      this.status = '请在系统设置中允许访问相册，然后重试';
    } finally {
      this.changingSettings = false;
    }
    if (this.galleryGranted) {
      this.sync();
    }
  }

  private manualTargetFromFields(): PairingTarget {
    const host = parseReceiverHost(this.host);
    const token = this.token.trim().toLowerCase();
    if (!host) {
      throw new Error('请输入 Mac 接收端显示的局域网 IPv4 地址');
    }
    if (!isPairingCode(token)) {
      throw new Error('请输入 Mac 接收端显示的 24 位配对码');
    }
    return new PairingTarget([host], token);
  }

  private async connect(useScanner: boolean = false, saved?: Pairing): Promise<void> {
    if (this.changingSettings || this.manualSending || this.selecting) {
      return;
    }
    this.changingSettings = true;
    this.pairingStatus = '';
    try {
      const context: common.UIAbilityContext = this.getContext();
      let target: PairingTarget | undefined;
      if (useScanner) {
        target = await scanPairing(context);
      } else if (saved) {
        target = new PairingTarget([saved.host], saved.token);
      } else {
        target = this.manualTargetFromFields();
      }
      if (!target || !this.pageReady) {
        return;
      }
      this.pairingStatus = '正在验证 Mac…';
      const verified = await findVerifiedHost(target.hosts, target.token);
      if (!this.pageReady) {
        return;
      }
      const pairing: Pairing = createPairing(context, verified.host, target.token, Date.now(), verified.mac, this.pairing);
      savePairing(context, pairing);
      Receiver.reportDevice(pairing.host, pairing.token, pairing.installation);
      this.stopListening();
      if (this.manualTarget && (this.manualTarget.destination !== pairing.destination ||
        this.manualTarget.host !== pairing.host)) {
        this.clearSelection();
        this.manualStatus = 'Mac 接收端已更改，请重新选择图片或视频';
      }
      this.applyPairing(pairing);
      this.macUnreachable = false;
      this.host = verified.host;
      this.token = target.token;
      this.pairingStatus = '';
      this.showSettings = false;
      this.refreshPermission();
      this.status = pairing.enabled && !this.galleryGranted ? '允许访问相册后可自动同步' : 'Mac 已连接';
      await this.refreshSchedule();
      this.startListening();
    } catch (error) {
      this.pairingStatus = error instanceof Error ? error.message : '配对失败，请检查 Mac 接收端';
      if (saved) {
        this.status = this.pairingStatus;
      }
    } finally {
      this.changingSettings = false;
      if (this.pairing?.pairedAfterMs !== undefined) {
        this.sync();
      }
    }
  }

  private async disconnect(): Promise<void> {
    if (this.changingSettings || this.manualSending || this.selecting) {
      return;
    }
    this.changingSettings = true;
    try {
      clearPairing(this.getContext());
      this.stopListening();
      this.clearSelection();
      this.pairing = undefined;
      this.hasPairing = false;
      this.syncEnabled = false;
      this.activeHost = '';
      this.recent = [];
      this.lastReceiptAt = 0;
      this.updateChat(undefined);
      this.cutoffLabel = '';
      this.token = '';
      this.showSettings = false;
      this.pairingStatus = '';
      this.status = '已断开 Mac';
      this.manualStatus = '';
      await this.refreshSchedule();
    } catch (_error) {
      this.status = '暂时无法断开 Mac，请稍后重试';
    } finally {
      this.changingSettings = false;
    }
  }

  private async setSyncEnabled(enabled: boolean): Promise<void> {
    const previous: Pairing | undefined = this.pairing;
    if (!previous || this.changingSettings || previous.enabled === enabled) {
      return;
    }
    this.changingSettings = true;
    try {
      const pairing: Pairing = withSyncEnabled(previous, enabled);
      savePairing(this.getContext(), pairing);
      this.applyPairing(pairing);
      if (enabled) {
        this.refreshPermission();
        this.startListening();
        this.status = '等待同步';
      } else {
        this.stopListening();
        this.status = '同步已停止';
      }
      await this.refreshSchedule();
    } catch (_error) {
      this.status = enabled ? '未能继续同步' : '未能停止同步';
    } finally {
      this.changingSettings = false;
    }
    if (enabled) {
      this.sync();
    }
  }

  private refreshSchedule(): Promise<void> {
    this.scheduleUpdate = this.scheduleUpdate.then(async (): Promise<void> => {
      const revision: number | undefined = this.syncEnabled && this.galleryGranted &&
        this.pairing?.pairedAfterMs !== undefined ? this.pairing.revision : undefined;
      try {
        await updateSchedule(this.getContext().abilityInfo.bundleName, revision);
        this.scheduleStatus = revision !== undefined ? '相册变化时立即检查。应用挂起后由系统安排补传。' : '';
      } catch (_error) {
        this.scheduleStatus = revision !== undefined ? '后台补传未能注册，打开应用时仍会同步。' : '';
      }
    });
    return this.scheduleUpdate;
  }

  private async sync(fromPhotoChange: boolean = false): Promise<void> {
    const pairing: Pairing | undefined = this.pairing;
    if (!this.pageReady || !pairing?.enabled || (!this.foreground && !fromPhotoChange) || this.changingSettings) {
      return;
    }
    if (this.uploading) {
      this.scanAgain = true;
      return;
    }
    if (pairing.pairedAfterMs === undefined) {
      this.connect(false, pairing);
      return;
    }
    this.refreshPermission();
    if (!this.galleryGranted) {
      this.stopListening();
      this.status = '等待相册授权';
      return;
    }
    const cancellation = new SyncCancellation();
    const previousStatus: string = this.status;
    this.activeSync = cancellation;
    this.uploading = true;
    this.status = '正在检查系统截图…';
    try {
      const result: SyncResult = await syncScreenshots(this.getContext(), pairing, cancellation, (): void => {
        this.prepareBackgroundContinuation(cancellation);
      });
      if (this.activeSync === cancellation) {
        if (result.uploaded > 0) { this.macUnreachable = false; }
        if (result.skipped > 0) {
          this.status = `本次同步 ${result.uploaded} 张，${result.skipped} 张暂未处理`;
        } else if (result.uploaded > 0) {
          this.status = `已同步 ${result.uploaded} 张截图`;
        } else {
          this.status = previousStatus.startsWith('已同步 ') ? previousStatus : '等待新截图';
        }
      }
    } catch (error) {
      if (this.activeSync === cancellation) {
        this.status = error instanceof Error ? error.message : '同步暂不可用，稍后自动重试';
      }
    } finally {
      if (this.activeSync === cancellation) {
        this.reloadRecent();
        this.activeSync = undefined;
        this.uploading = false;
        this.releaseBackgroundDelay();
        const repeat = this.scanAgain;
        this.scanAgain = false;
        if (repeat) {
          this.sync(true);
        }
      }
    }
  }

  private clearSelection(): void {
    const selection: SelectedMedia[] = this.selection;
    this.selection = [];
    this.reviewing = false;
    this.manualTarget = undefined;
    for (const item of selection) {
      item.thumbnail?.release().catch((): void => {});
    }
  }

  private async pickMedia(): Promise<void> {
    const pairing: Pairing | undefined = this.pairing;
    if (!pairing || this.selecting || this.manualSending || this.changingSettings) {
      return;
    }
    this.selecting = true;
    this.manualStatus = '';
    try {
      const picked: SelectedMedia[] = await selectMedia(this.getContext(), pairing);
      if (!this.pageReady || this.pairing?.destination !== pairing.destination || this.pairing?.host !== pairing.host) {
        for (const item of picked) {
          item.thumbnail?.release().catch((): void => {});
        }
        return;
      }
      if (picked.length > 0) {
        this.clearSelection();
        this.selection = picked;
        this.manualTarget = pairing;
        this.reviewing = true;
      }
    } catch (_error) {
      this.manualStatus = '无法打开系统相册，请重试';
    } finally {
      this.selecting = false;
    }
  }

  private async sendMedia(): Promise<void> {
    const target: Pairing | undefined = this.manualTarget;
    if (!target || this.manualSending || this.selection.length === 0 || this.changingSettings) {
      return;
    }
    const cancellation = new SyncCancellation();
    this.activeManual = cancellation;
    this.manualSending = true;
    this.manualStatus = '正在手动发送…';
    try {
      const result: ManualResult = await sendSelection(this.getContext(), target, this.selection, cancellation);
      if (this.activeManual !== cancellation) {
        return;
      }
      this.reloadRecent();
      const completed = new Set(result.completed);
      this.selection = this.selection.filter((item: SelectedMedia): boolean => {
        if (!completed.has(item.uri)) {
          return true;
        }
        item.thumbnail?.release().catch((): void => {});
        return false;
      });
      if (this.selection.length === 0) {
        this.manualTarget = undefined;
        this.reviewing = false;
        this.manualStatus = `已同步 ${completed.size} 项媒体`;
      } else if (cancellation.stopped) {
        this.manualStatus = `已取消本次发送，剩余 ${this.selection.length} 项可重试`;
      } else {
        const message: string = result.error || '请检查 Mac 接收端后重试';
        this.manualStatus = `剩余 ${this.selection.length} 项。${message}`;
      }
    } finally {
      if (this.activeManual === cancellation) {
        this.activeManual = undefined;
        this.manualSending = false;
      }
    }
  }

  @Builder
  private scanButton() {
    Button(this.hasPairing ? '扫码更换 Mac' : '扫码连接 Mac')
      .width(this.hasPairing ? 'auto' : '100%').height(44)
      .fontSize(this.hasPairing ? 14 : 16).fontWeight(FontWeight.Medium)
      .backgroundColor(this.hasPairing ? '#33695A' : '#F0F8F1')
      .fontColor(this.hasPairing ? '#FFFFFF' : '#153F33')
      .enabled(!this.changingSettings && !this.manualSending && !this.selecting)
      .onClick(() => { this.connect(true); })
  }

  @Builder
  private destination(name: string) {
    if (name === CHAT_ROUTE && this.chat) {
      ChatPage({ session: this.chat })
    }
  }

  build() {
    Navigation(this.pathStack) {
      this.home()
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.destination)
  }

  @Builder
  private home() {
    Column() {
      Row({ space: 5 }) {
        Text($r('app.string.app_name')).fontSize(32).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
        Text(this.version.trim()).fontSize(13).fontColor($r('app.color.secondary_text'))
        Blank().layoutWeight(1)
        if (this.hasPairing) {
          Button('设置').fontSize(14).height(44).fontColor($r('app.color.ink')).backgroundColor($r('app.color.soft'))
            .enabled(!this.changingSettings && !this.manualSending && !this.selecting)
            .onClick(() => { this.showSettings = true; })
        }
      }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 18, right: 18, top: 8, bottom: 7 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.hasPairing) {
            this.pairedDevice()
          } else {
            this.firstConnection()
          }
          if (this.pairingStatus) {
            Text(this.pairingStatus).fontSize(14).fontColor($r('app.color.secondary_text')).width('100%')
          }
          if (this.hasPairing) {
            if (this.syncEnabled && !this.galleryGranted) {
              Row({ space: 10 }) {
                Text('自动同步需要相册权限').fontSize(14).fontColor($r('app.color.ink')).layoutWeight(1)
                Button('允许访问相册').height(44).fontSize(14).fontColor($r('app.color.accent_text'))
                  .backgroundColor($r('app.color.soft')).enabled(!this.changingSettings)
                  .onClick(() => { this.grantGalleryAccess(); })
              }.width('100%')
            }
            if (this.status && !['Mac 已连接', '等待相册授权', '允许访问相册后可自动同步', '等待同步', '等待新截图', '同步已停止'].includes(this.status) &&
              !this.status.startsWith('已同步 ')) {
              Text(this.status).fontSize(14).fontColor($r('app.color.secondary_text')).width('100%')
            }
            if (this.chat) {
              ChatEntry({ session: this.chat, open: () => {
                if (this.pathStack.size() === 0) { this.pathStack.pushPath({ name: CHAT_ROUTE }); }
              } })
            }
            this.historyRows()
          }
        }.alignItems(HorizontalAlign.Start).width('100%').constraintSize({ maxWidth: 540 })
        .padding({ left: 18, right: 18, top: 8, bottom: 20 })
      }.layoutWeight(1).align(Alignment.Top).width('100%').scrollBar(BarState.Auto)

      if (this.hasPairing) {
        Column({ space: 5 }) {
          if (this.manualStatus && !this.reviewing) {
            Text(this.manualStatus).fontSize(13).fontColor($r('app.color.secondary_text'))
          }
          Button(this.selecting ? '正在选择' : '手动发送').width('100%').height(48)
            .fontColor(Color.White).backgroundColor(PINE)
            .enabled(!this.manualSending && !this.selecting && !this.changingSettings)
            .onClick(() => { this.pickMedia(); })
        }.width('100%').constraintSize({ maxWidth: 540 }).padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .backgroundBlurStyle(BlurStyle.Thin).backgroundColor($r('app.color.dock'))
        .bindSheet(this.reviewing, this.confirmSheet(), {
          height: SheetSize.FIT_CONTENT, onWillDismiss: (action: DismissSheetAction) => {
            if (!this.manualSending) { action.dismiss(); }
          }, onDisappear: () => {
            if (this.reviewing && !this.manualSending) { this.clearSelection(); this.manualStatus = ''; }
          }
        })
      }
    }.height('100%').width('100%').backgroundColor($r('app.color.window_background'))
    .bindSheet(this.showSettings, this.settingsSheet(), {
      height: SheetSize.LARGE, onDisappear: () => { this.showSettings = false; }
    })
  }

  @Builder
  private firstConnection() {
    Column({ space: 12 }) {
      Text('尚未配对').fontColor(MIST).fontSize(13)
      Image($r('app.media.pairing_display')).height(90).width('100%').objectFit(ImageFit.Contain).accessibilityLevel('no')
      Text('连接你的 Mac').fontSize(26).fontWeight(FontWeight.Bold).fontColor(Color.White)
      Text('配对后，新截的图会自动传到 Mac。').fontSize(14).fontColor(MIST)
      this.scanButton()
    }.alignItems(HorizontalAlign.Start).width('100%').padding(20).borderRadius(22)
    .linearGradient({ angle: 140, colors: [['#34695B', 0], ['#143E33', 1]] })
    Button('手动输入地址和配对码').fontColor($r('app.color.accent_text')).backgroundColor(Color.Transparent)
      .width('100%').height(44).onClick(() => { this.showSettings = true; })
    Text('在 Mac 上打开配对码').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink'))
    Text('手机和 Mac 接入同一局域网后，在 Mac 端即图右上角点「扫码配对」。')
      .fontSize(15).fontColor($r('app.color.secondary_text'))
  }

  @Builder
  private pairedDevice() {
    Column({ space: 10 }) {
      Row() {
        Column({ space: 4 }) {
          Text('已配对设备 · ' + familyName(this.mac.family)).fontSize(13).fontColor(MIST)
          Text(macDisplayName(this.mac)).fontSize(22).fontWeight(FontWeight.Bold).fontColor(Color.White)
          Text(this.macUnreachable ? '上次连接检查失败' : this.lastReceiptAt ? '上次成功传输 ' + this.deliveryTime(this.lastReceiptAt) : '暂无送达记录')
            .fontSize(13).fontColor(MIST)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image(macArtwork(this.mac.family)).width(92).height(62).objectFit(ImageFit.Contain)
          .accessibilityLevel('no')
      }.width('100%')
      this.scanButton()
      Divider().color('#598476')
      Row({ space: 7 }) {
        Circle().width(8).height(8).fill(this.syncEnabled ? '#8FE2AA' : '#FF9B91')
        Text(this.syncEnabled ? '自动同步已开启' : '自动同步已暂停')
          .fontColor(Color.White).fontSize(15).fontWeight(FontWeight.Medium).layoutWeight(1)
        Button(this.syncEnabled ? '暂停' : '继续').fontSize(14).height(44).fontColor(Color.White)
          .backgroundColor('#33695A').enabled(!this.changingSettings)
          .onClick(() => { this.setSyncEnabled(!this.syncEnabled); })
      }.width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%').padding(18).borderRadius(22)
    .linearGradient({ angle: 140, colors: [['#34695B', 0], ['#143E33', 1]] })
  }

  @Builder
  private historyRows() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('最近传输').fontSize(20).fontColor($r('app.color.ink')).fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        if (this.recent.length) {
          Button('清除记录').fontSize(14).height(44)
            .fontColor($r('app.color.accent_text')).backgroundColor($r('app.color.soft'))
            .onClick(() => { this.confirmClearRecent(); })
        }
      }.width('100%')
      if (!this.recent.length) {
        Text('Mac 收到图片或视频后，会在这里显示。').fontSize(14).fontColor($r('app.color.secondary_text'))
          .padding({ top: 6, bottom: 6 })
      }
      ForEach(this.recent, (item: Delivery) => {
        Row({ space: 10 }) {
          if (item.thumbnail) {
            Image(item.thumbnail).width(44).height(50).objectFit(ImageFit.Cover).borderRadius(8).accessibilityLevel('no')
          } else {
            Text(item.video ? '视频' : '图片').fontSize(12).fontColor($r('app.color.accent_text'))
              .width(44).height(50).textAlign(TextAlign.Center).backgroundColor($r('app.color.soft')).borderRadius(8)
          }
          Column({ space: 4 }) {
            Text(item.name).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontSize(15).fontColor($r('app.color.ink')).fontWeight(FontWeight.Medium)
            Text((item.manual ? '手动发送' : '自动同步') + ' · ' + chatSize(item.bytes))
              .fontSize(12).fontColor($r('app.color.secondary_text'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Column({ space: 4 }) {
            Text(this.deliveryTime(item.time)).fontSize(12).fontColor($r('app.color.secondary_text'))
            Text('已送达').fontSize(12).fontColor($r('app.color.accent_text'))
          }.alignItems(HorizontalAlign.End)
        }.width('100%').padding({ top: 7, bottom: 7 })
        Divider().color($r('app.color.line'))
      }, (item: Delivery): string => item.id)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private settingsSheet() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.hasPairing ? '连接与同步' : '手动连接 Mac').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
        if (this.hasPairing) {
          Text(macDisplayName(this.mac) + ' · ' + this.receiverDetails()).fontColor($r('app.color.secondary_text'))
          if (this.cutoffLabel) {
            Text('仅自动发送 ' + this.cutoffLabel + ' 配对后截取的新图。').fontSize(14).fontColor($r('app.color.secondary_text'))
          }
          if (this.scheduleStatus) {
            Text(this.scheduleStatus).fontSize(14).fontColor($r('app.color.secondary_text'))
          }
        }
        Text('Mac 局域网地址').fontColor($r('app.color.ink'))
        TextInput({ text: this.host, placeholder: '192.168.1.20:43871' })
          .id(HOST_INPUT_ID).maxLength(21).enabled(!this.changingSettings)
          .fontColor($r('app.color.ink')).backgroundColor($r('app.color.soft'))
          .onChange((value: string) => { this.host = value; })
        Text('配对码').fontColor($r('app.color.ink'))
        TextInput({ text: this.token, placeholder: '24 位配对码' }).type(InputType.Password)
          .id(TOKEN_INPUT_ID).maxLength(24).enabled(!this.changingSettings)
          .fontColor($r('app.color.ink')).backgroundColor($r('app.color.soft'))
          .onChange((value: string) => { this.token = value; })
        Button(this.changingSettings ? '正在验证' : '连接 Mac').width('100%').height(46)
          .backgroundColor(PINE).fontColor(Color.White).enabled(!this.changingSettings)
          .onClick(() => { this.connect(); })
        if (this.pairingStatus) {
          Text(this.pairingStatus).fontSize(14).fontColor($r('app.color.secondary_text'))
        }
        if (this.hasPairing) {
          Button('断开 Mac').fontColor($r('app.color.warning')).backgroundColor(Color.Transparent)
            .enabled(!this.changingSettings).onClick(() => { this.disconnect(); })
        }
        Button('关闭').fontColor($r('app.color.accent_text')).backgroundColor($r('app.color.soft'))
          .onClick(() => { this.showSettings = false; })
      }.alignItems(HorizontalAlign.Start).width('100%').padding(22)
    }.backgroundColor($r('app.color.surface')).width('100%')
  }

  @Builder
  private confirmSheet() {
    Column({ space: 12 }) {
      Text('确认发送').fontSize(22).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
      Text('发送到 ' + macDisplayName(this.mac)).fontSize(16).fontColor($r('app.color.ink'))
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.selection, (item: SelectedMedia) => {
            Column({ space: 2 }) {
              if (item.thumbnail) {
                Image(item.thumbnail).width(70).height(70).borderRadius(8).objectFit(ImageFit.Cover).accessibilityText(item.name)
              } else {
                Text(item.name || (item.isVideo ? '视频' : '图片')).fontSize(12).width(70).height(70)
                  .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor($r('app.color.secondary_text'))
              }
              Text(item.isVideo ? '视频' : '照片').fontSize(12).fontColor($r('app.color.secondary_text'))
            }
          }, (item: SelectedMedia): string => item.uri)
        }
      }.width('100%').scrollable(ScrollDirection.Horizontal)
      if (this.manualStatus) {
        Text(this.manualStatus).fontSize(14).fontColor($r('app.color.secondary_text'))
      }
      if (this.manualSending) {
        Button('取消本次发送').fontColor($r('app.color.accent_text')).backgroundColor($r('app.color.soft'))
          .onClick(() => { this.activeManual?.stop(); })
      } else {
        Button('发送 ' + this.selection.length + ' 项').width('100%').height(46).backgroundColor(PINE).fontColor(Color.White)
          .enabled(this.selection.length > 0).onClick(() => { this.sendMedia(); })
        Button('返回').fontColor($r('app.color.accent_text')).backgroundColor(Color.Transparent)
          .onClick(() => { this.clearSelection(); this.manualStatus = ''; })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor($r('app.color.surface'))
  }
}
