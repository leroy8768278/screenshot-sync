import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { createPairing, loadPairing, Pairing, savePairing } from '../sync/Pairing';
import { isPairingCode, parseReceiverHost, RECEIVER_PORT } from '../sync/Protocol';
import { Receiver } from '../sync/Receiver';
import { GALLERY_PERMISSION, galleryAllowed, syncScreenshots, SyncResult } from '../sync/ScreenshotSync';
import { updateSchedule } from '../work/Schedule';

const BLUE: string = '#2359D7';
const INK: string = '#162444';
const MUTED: string = '#475975';

@Entry
@Component
struct Index {
  @StorageProp('syncForeground') @Watch('foregroundChanged') private foreground: boolean = false;
  @State private host: string = '';
  @State private token: string = '';
  @State private includeExisting: boolean = false;
  @State private syncEnabled: boolean = false;
  @State private hasPairing: boolean = false;
  @State private activeHost: string = '';
  @State private galleryGranted: boolean = false;
  @State private changingSettings: boolean = false;
  @State private uploading: boolean = false;
  @State private status: string = '等待配对';
  @State private scheduleStatus: string = '';

  private getContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private pairing: Pairing | undefined;
  private helper: photoAccessHelper.PhotoAccessHelper | undefined;
  private interval: number = -1;
  private debounce: number = -1;
  private generation: number = 0;
  private pageReady: boolean = false;

  private onPhotoChange = (_change: photoAccessHelper.PhotoAssetChangeInfos): void => {
    if (this.debounce !== -1) {
      clearTimeout(this.debounce);
    }
    this.debounce = setTimeout((): void => {
      this.debounce = -1;
      this.sync();
    }, 1200);
  };

  aboutToAppear(): void {
    this.pageReady = true;
    try {
      this.pairing = loadPairing(this.getContext());
      if (this.pairing) {
        this.host = this.pairing.host;
        this.token = this.pairing.token;
        this.applyPairing(this.pairing);
        this.status = this.syncEnabled ? '等待同步' : '已暂停';
      }
      this.foregroundChanged();
    } catch (_error) {
      this.status = '无法读取配对设置，请重新配对';
    }
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.stopListening();
  }

  private applyPairing(pairing: Pairing): void {
    this.pairing = pairing;
    this.syncEnabled = pairing.enabled;
    this.hasPairing = true;
    this.activeHost = pairing.host;
  }

  private foregroundChanged(): void {
    if (!this.pageReady || !this.foreground) {
      this.stopListening();
      return;
    }
    this.refreshPermission();
    this.startListening();
    if (this.syncEnabled) {
      this.refreshSchedule();
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
    if (!this.foreground || !this.syncEnabled || !this.galleryGranted || this.interval !== -1) {
      return;
    }
    this.interval = setInterval((): void => {
      this.sync();
    }, 30_000);
    try {
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.getContext());
      helper.on('photoChange', this.onPhotoChange);
      this.helper = helper;
    } catch (_error) {
      // The periodic foreground scan also covers missed photo change notifications.
    }
  }

  private stopListening(): void {
    this.generation++;
    if (this.interval !== -1) {
      clearInterval(this.interval);
      this.interval = -1;
    }
    if (this.debounce !== -1) {
      clearTimeout(this.debounce);
      this.debounce = -1;
    }
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

  private async connect(): Promise<void> {
    if (this.changingSettings || this.uploading) {
      return;
    }
    const host: string | undefined = parseReceiverHost(this.host);
    const token: string = this.token.trim().toLowerCase();
    if (!host) {
      this.status = '请输入 Mac 接收端显示的局域网 IPv4 地址';
      return;
    }
    if (!isPairingCode(token)) {
      this.status = '请输入 Mac 接收端显示的 24 位配对码';
      return;
    }

    this.changingSettings = true;
    this.status = '正在连接 Mac…';
    let receiver: Receiver | undefined;
    try {
      receiver = new Receiver(host, token);
      await receiver.verify();
      await this.authorizeGallery();
      const pairing: Pairing = createPairing(host, token, this.includeExisting, this.pairing);
      savePairing(this.getContext(), pairing);
      this.applyPairing(pairing);
      this.host = host;
      this.token = token;
      this.includeExisting = false;
      this.status = 'Mac 已配对';
      await this.refreshSchedule();
      this.startListening();
    } catch (error) {
      this.status = error instanceof Error ? error.message : '配对失败，请检查 Mac 和相册权限';
      return;
    } finally {
      receiver?.close();
      this.changingSettings = false;
    }
    this.sync();
  }

  private async pause(): Promise<void> {
    const previous: Pairing | undefined = this.pairing;
    if (!previous || this.changingSettings) {
      return;
    }
    this.changingSettings = true;
    try {
      const paused = new Pairing(previous.host, previous.token, previous.sinceMs,
        previous.installation, previous.destination, false);
      savePairing(this.getContext(), paused);
      this.applyPairing(paused);
      this.stopListening();
      this.status = '已暂停';
      await this.refreshSchedule();
    } catch (_error) {
      this.status = '未能保存暂停设置';
    } finally {
      this.changingSettings = false;
    }
  }

  private async refreshSchedule(): Promise<void> {
    const enabled: boolean = this.syncEnabled && this.galleryGranted;
    try {
      await updateSchedule(this.getContext().abilityInfo.bundleName, enabled);
      this.scheduleStatus = enabled ? '后台补传由系统择机执行。' : '';
    } catch (_error) {
      this.scheduleStatus = enabled ? '后台补传未能注册，打开应用时仍会同步。' : '';
    }
  }

  private async sync(): Promise<void> {
    const pairing: Pairing | undefined = this.pairing;
    if (!pairing?.enabled || !this.foreground || this.uploading || this.changingSettings) {
      return;
    }
    this.refreshPermission();
    if (!this.galleryGranted) {
      this.stopListening();
      this.status = '等待相册授权';
      return;
    }
    const generation: number = this.generation;
    const previousStatus: string = this.status;
    this.uploading = true;
    this.status = '正在检查系统截图…';
    try {
      const result: SyncResult = await syncScreenshots(this.getContext(), pairing,
        (): boolean => this.syncEnabled && this.foreground && this.generation === generation);
      if (this.generation === generation) {
        if (result.skipped > 0) {
          this.status = `本次同步 ${result.uploaded} 张，${result.skipped} 张暂未处理`;
        } else if (result.uploaded > 0) {
          this.status = `已同步 ${result.uploaded} 张截图`;
        } else {
          this.status = previousStatus.startsWith('已同步 ') ? previousStatus : '等待新截图';
        }
      }
    } catch (error) {
      if (this.generation === generation) {
        this.status = error instanceof Error ? error.message : '同步暂不可用，稍后自动重试';
      }
    } finally {
      this.uploading = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 7 }) {
          Text('截图同步')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text('将手机截图通过局域网发到 Mac')
            .fontSize(15)
            .fontColor(MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: 18, bottom: 4 })

        Column({ space: 9 }) {
          Text(this.syncEnabled ? '自动同步已开启' : this.hasPairing ? '自动同步已暂停' : '尚未连接 Mac')
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
          }
          if (this.scheduleStatus.length > 0) {
            Text(this.scheduleStatus)
              .fontSize(14)
              .fontColor(MUTED)
          }
          if (this.syncEnabled && !this.galleryGranted) {
            Button('授权读取相册')
              .backgroundColor(BLUE)
              .enabled(!this.changingSettings)
              .onClick(() => { this.grantGalleryAccess(); })
          }
          if (this.syncEnabled) {
            Row({ space: 10 }) {
              if (this.galleryGranted) {
                Button('立即同步')
                  .backgroundColor(BLUE)
                  .enabled(!this.uploading && !this.changingSettings)
                  .onClick(() => { this.sync(); })
              }
              Button('暂停')
                .backgroundColor('#EAF0FF')
                .fontColor(INK)
                .enabled(!this.changingSettings)
                .onClick(() => { this.pause(); })
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(22)

        Column({ space: 12 }) {
          Text('连接设置')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text('打开 Mac 接收端，填写它显示的地址和配对码。')
            .fontSize(14)
            .fontColor(MUTED)
          Text('Mac 局域网地址')
            .fontSize(14)
            .fontColor(INK)
          TextInput({ text: this.host, placeholder: '192.168.1.20:43871' })
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
            .type(InputType.Password)
            .width('100%')
            .backgroundColor('#F3F6FC')
            .fontColor(INK)
            .maxLength(24)
            .enabled(!this.changingSettings)
            .onChange((value: string) => { this.token = value; })
          if (!this.hasPairing || this.token.trim().toLowerCase() !== this.pairing?.token) {
            Row({ space: 6 }) {
              Checkbox()
                .select(this.includeExisting)
                .selectedColor(BLUE)
                .accessibilityText('同时同步已有截图')
                .onChange((value: boolean) => { this.includeExisting = value; })
              Text('同时同步已有截图')
                .fontSize(15)
                .fontColor(INK)
            }
          }
          Button(this.syncEnabled ? '验证并保存' : this.hasPairing ? '恢复同步' : '配对并开启同步')
            .width('100%')
            .backgroundColor(BLUE)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .enabled(!this.changingSettings && !this.uploading)
            .onClick(() => { this.connect(); })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(20)
        .backgroundColor('#FFFFFF')
        .borderRadius(22)

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
  }
}
