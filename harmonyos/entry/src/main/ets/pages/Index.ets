import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { clearPairing, createPairing, loadPairing, Pairing, savePairing, withSyncEnabled } from '../sync/Pairing';
import { ManualResult, SelectedMedia, selectMedia, sendSelection } from '../sync/ManualSync';
import { isPairingCode, PairingTarget, parseReceiverHost, RECEIVER_PORT } from '../sync/Protocol';
import { findVerifiedHost, Receiver } from '../sync/Receiver';
import { scanPairing } from '../sync/ScanPairing';
import { GALLERY_PERMISSION, galleryAllowed, syncScreenshots, SyncCancellation, SyncResult } from '../sync/ScreenshotSync';
import { updateSchedule } from '../work/Schedule';

import { CHAT_INPUT_ID, ChatCard } from './ChatCard';

const BLUE: string = '#2359D7';
const INK: string = '#162444';
const MUTED: string = '#475975';
const HOST_INPUT_ID: string = 'receiver-host-input';
const TOKEN_INPUT_ID: string = 'receiver-token-input';
const DISMISS_CHAT_KEYBOARD: string = 'dismiss-chat-keyboard';

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
  private readonly chatEditor: TextAreaController = new TextAreaController();
  @StorageProp('syncForeground') @Watch('foregroundChanged') private foreground: boolean = false;
  @State private host: string = '';
  @State private token: string = '';
  @State private syncEnabled: boolean = false;
  @State private hasPairing: boolean = false;
  @State private activeHost: string = '';
  @State private chatRoom: string = '';
  @State private cutoffLabel: string = '';
  @State private showSettings: boolean = false;
  @State private galleryGranted: boolean = false;
  @State private changingSettings: boolean = false;
  @State private pairingStatus: string = '';
  @State private uploading: boolean = false;
  @State private status: string = '等待配对';
  @State private scheduleStatus: string = '';
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
    this.stopListening();
    this.activeManual?.stop();
    this.activeManual = undefined;
    this.manualSending = false;
    this.clearSelection();
  }

  private applyPairing(pairing: Pairing): void {
    this.pairing = pairing;
    this.syncEnabled = pairing.enabled;
    this.hasPairing = true;
    this.activeHost = pairing.host;
    this.chatRoom = pairing.pairedAfterMs !== undefined ? pairing.destination + ':' + pairing.host : '';
    if (pairing.pairedAfterMs !== undefined) {
      const date = new Date(pairing.pairedAfterMs);
      this.cutoffLabel = date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
    } else {
      this.cutoffLabel = '';
    }
  }

  private foregroundChanged(): void {
    if (!this.pageReady) {
      return;
    }
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
    this.startListening();
    if (this.hasPairing) {
      this.refreshSchedule();
    }
    if (this.syncEnabled) {
      this.sync();
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
      const host = await findVerifiedHost(target.hosts, target.token);
      if (!this.pageReady) {
        return;
      }
      const pairing: Pairing = createPairing(context, host, target.token, Date.now(), this.pairing);
      savePairing(context, pairing);
      Receiver.reportDevice(pairing.host, pairing.token, pairing.installation);
      this.stopListening();
      if (this.manualTarget && (this.manualTarget.destination !== pairing.destination ||
        this.manualTarget.host !== pairing.host)) {
        this.clearSelection();
        this.manualStatus = 'Mac 接收端已更改，请重新选择图片或视频';
      }
      this.applyPairing(pairing);
      this.host = host;
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
      this.chatRoom = '';
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
  private pairingScanner() {
    Button(this.hasPairing ? '扫码更换 Mac' : '扫一扫配对')
      .width('100%')
      .backgroundColor(this.hasPairing ? '#EAF0FF' : BLUE)
      .fontColor(this.hasPairing ? INK : '#FFFFFF')
      .enabled(!this.changingSettings && !this.manualSending && !this.selecting)
      .onClick(() => { this.connect(true); })
    if (this.pairingStatus.length > 0) {
      Text(this.pairingStatus)
        .fontSize(14)
        .fontColor(INK)
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 7 }) {
          Text() {
            Span($r('app.string.app_name'))
              .fontSize(34)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK)
            Span(this.version)
              .fontSize(15)
              .fontColor(MUTED)
          }
          Text($r('app.string.module_description'))
            .fontSize(15)
            .fontColor(MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 18, bottom: 4 })

        Column({ space: 9 }) {
          Text(!this.hasPairing ? '尚未连接 Mac' : !this.syncEnabled ? '自动同步已暂停' :
            this.galleryGranted ? '自动同步已开启' : '等待相册授权')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text(this.status)
            .fontSize(15)
            .fontColor(MUTED)
          if (this.hasPairing) {
            Text(`Mac · ${this.activeHost}:${RECEIVER_PORT}`)
              .fontSize(14)
              .fontColor(MUTED)
            if (!this.showSettings) {
              this.pairingScanner()
            }
            if (this.cutoffLabel.length > 0) {
              Text(`自动同步起点 · ${this.cutoffLabel}`)
                .fontSize(14)
                .fontColor(MUTED)
            }
          }
          if (this.scheduleStatus.length > 0) {
            Text(this.scheduleStatus)
              .fontSize(14)
              .fontColor(MUTED)
          }
          if (this.syncEnabled && !this.galleryGranted) {
            Button('允许访问相册')
              .backgroundColor(BLUE)
              .enabled(!this.changingSettings)
              .onClick(() => { this.grantGalleryAccess(); })
          }
          if (this.syncEnabled) {
            Button('暂停自动同步')
              .backgroundColor('#EAF0FF')
              .fontColor(INK)
              .enabled(!this.changingSettings)
              .onClick(() => { this.setSyncEnabled(false); })
          } else if (this.hasPairing) {
            Button('继续自动同步')
              .backgroundColor(BLUE)
              .enabled(!this.changingSettings)
              .onClick(() => { this.setSyncEnabled(true); })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(22)

        if (this.chatRoom.length > 0) {
          ChatCard({ room: this.chatRoom, editor: this.chatEditor })
        }
        if (this.hasPairing) {
          Button(this.selecting ? '正在选择媒体…' : '手动选图或视频')
            .width('100%')
            .backgroundColor(BLUE)
            .enabled(!this.manualSending && !this.selecting && !this.changingSettings)
            .onClick(() => { this.pickMedia(); })

          if (this.selection.length > 0) {
            Column({ space: 10 }) {
              Text('确认发送')
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor(INK)
              Text(`将 ${this.selection.length} 项媒体发送到 Mac · ${this.activeHost}:${RECEIVER_PORT}`)
                .fontSize(14)
                .fontColor(MUTED)
              Scroll() {
                Row({ space: 8 }) {
                  ForEach(this.selection, (item: SelectedMedia) => {
                    Stack({ alignContent: Alignment.BottomEnd }) {
                      if (item.thumbnail) {
                        Image(item.thumbnail)
                          .objectFit(ImageFit.Cover)
                          .width(76)
                          .height(76)
                          .borderRadius(8)
                          .accessibilityText(item.name || (item.isVideo ? '选中的视频' : '选中的图片'))
                        if (item.isVideo) {
                          Text('视频')
                            .fontSize(10)
                            .fontColor('#FFFFFF')
                            .backgroundColor(INK)
                            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                            .borderRadius(4)
                            .margin(4)
                        }
                      } else {
                        Text(item.name || (item.isVideo ? '选中的视频' : '选中的图片'))
                          .fontSize(11)
                          .fontColor(MUTED)
                          .textAlign(TextAlign.Center)
                          .maxLines(3)
                          .width(76)
                          .height(76)
                          .backgroundColor('#EAF0FF')
                          .borderRadius(8)
                      }
                    }
                  }, (item: SelectedMedia): string => item.uri)
                }
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Auto)
              if (this.manualSending) {
                Button('取消本次发送')
                  .backgroundColor('#EAF0FF')
                  .fontColor(INK)
                  .onClick(() => { this.activeManual?.stop(); })
              } else {
                Row({ space: 8 }) {
                  Button(`发送 ${this.selection.length} 项`)
                    .backgroundColor(BLUE)
                    .enabled(!this.changingSettings && !this.selecting)
                    .onClick(() => { this.sendMedia(); })
                  Button('返回')
                    .backgroundColor('#EAF0FF')
                    .fontColor(INK)
                    .enabled(!this.selecting)
                    .onClick(() => { this.clearSelection(); this.manualStatus = ''; })
                }
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(20)
            .backgroundColor('#FFFFFF')
            .borderRadius(22)
          }
          if (this.manualStatus.length > 0) {
            Text(this.manualStatus)
              .fontSize(14)
              .fontColor(MUTED)
              .width('100%')
          }
          Button(this.showSettings ? '收起连接设置' : '连接设置')
            .backgroundColor('#EAF0FF')
            .fontColor(INK)
            .enabled(!this.manualSending && !this.selecting && !this.changingSettings)
            .onClick(() => { this.showSettings = !this.showSettings; })
        }

        if (!this.hasPairing || this.showSettings) {
          Column({ space: 12 }) {
            Text(this.hasPairing ? '连接设置' : '连接 Mac')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK)
            Text('在 Mac 上点「扫码配对」显示二维码。')
              .fontSize(14)
              .fontColor(MUTED)
            this.pairingScanner()
            Text('也可以手动输入 Mac 上显示的地址和配对码。')
              .fontSize(14)
              .fontColor(MUTED)
            Text('Mac 局域网地址')
              .fontSize(14)
              .fontColor(INK)
            TextInput({ text: this.host, placeholder: '192.168.1.20:43871' })
              .id(HOST_INPUT_ID)
              .type(InputType.Normal)
              .width('100%')
              .backgroundColor('#F3F6FC')
              .fontColor(INK)
              .maxLength(21)
              .enabled(!this.changingSettings)
              .onChange((value: string) => { this.host = value; })
            Text('配对码')
              .fontSize(14)
              .fontColor(INK)
            TextInput({ text: this.token, placeholder: '24 位配对码' })
              .id(TOKEN_INPUT_ID)
              .type(InputType.Password)
              .width('100%')
              .backgroundColor('#F3F6FC')
              .fontColor(INK)
              .maxLength(24)
              .enabled(!this.changingSettings)
              .onChange((value: string) => { this.token = value; })
            Button(this.hasPairing ? '验证并保存' : '连接 Mac')
              .width('100%')
              .backgroundColor('#EAF0FF')
              .fontColor(INK)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .enabled(!this.changingSettings && !this.manualSending && !this.selecting)
              .onClick(() => { this.connect(); })
            if (this.hasPairing) {
              Button('断开 Mac')
                .backgroundColor('#EAF0FF')
                .fontColor(INK)
                .enabled(!this.changingSettings && !this.manualSending && !this.selecting)
                .onClick(() => { this.disconnect(); })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(20)
          .backgroundColor('#FFFFFF')
          .borderRadius(22)
        }

        Text('请在可信的 Wi-Fi 下使用。截图与配对码通过局域网 HTTP 传输。')
          .fontSize(13)
          .fontColor(MUTED)
          .width('100%')
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .padding({ left: 20, right: 20, bottom: 28 })
    }
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
    .backgroundColor('#F3F6FC')
    .scrollBar(BarState.Off)
    .parallelGesture(TapGesture().tag(DISMISS_CHAT_KEYBOARD).onAction(() => {
      this.chatEditor.stopEditing();
    }))
    .onTouchTestDone((_event: BaseGestureEvent, recognizers: GestureRecognizer[]) => {
      const editingField = recognizers.some((r: GestureRecognizer): boolean => {
        const id = r.getEventTargetInfo().getId();
        return id === CHAT_INPUT_ID || id === HOST_INPUT_ID || id === TOKEN_INPUT_ID;
      });
      if (editingField) {
        recognizers.find((r: GestureRecognizer): boolean => r.getTag() === DISMISS_CHAT_KEYBOARD)?.preventBegin();
      }
    })
  }
}
