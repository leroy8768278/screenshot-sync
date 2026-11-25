import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ChatAttachment, ChatMessage, chatKey, chatSize, MAX_CHAT_FILE, MAX_CHAT_TEXT } from '../sync/ChatTypes';
import { ChatDownload, chatDownloads, chatRoomKey, deleteChatDownload, trackChatDownload } from '../sync/ChatDownloads';
import { loadPairing, Pairing } from '../sync/Pairing';
import { Receiver } from '../sync/Receiver';

export const CHAT_INPUT_ID: string = 'chat-message-input';

@Component
export struct ChatCard {
  editor?: TextAreaController;
  @Prop @Watch('resetRoom') room: string = '';
  @StorageProp('syncForeground') @Watch('schedule') foreground: boolean = false;
  @State private opened: boolean = false;
  @State private messages: ChatMessage[] = [];
  @State private lastRead: number = 0;
  @State private mac: string = 'Mac';
  @State private draft: string = '';
  @State private files: ChatAttachment[] = [];
  @State private busy: boolean = false;
  @State private notice: string = '';
  @State private networkError: string = '';
  @State private received: string[] = [];
  @State private previewId: string = '';
  @State private preview: string = '';
  @State private showingClear: boolean = false;
  @State private clearFiles: boolean = false;
  @State private clearCount: number = 0;
  @State private downloads: ChatDownload[] = [];
  private clearSequence: number = 0;
  private clearedThrough: number = 0;
  private timer: number = -1;
  private generation: number = 0;
  private polling: boolean = false;
  private mounted: boolean = false;
  private textID: string = '';
  private transfers: Set<Receiver> = new Set();
  private scroller: Scroller = new Scroller();

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private pairing(): Pairing | undefined {
    const target = loadPairing(this.context());
    if (target && target.pairedAfterMs !== undefined && target.destination + ':' + target.host === this.room) {
      return target;
    }
    return undefined;
  }

  aboutToAppear(): void {
    this.mounted = true;
    this.resetRoom();
  }

  aboutToDisappear(): void {
    this.mounted = false;
    this.generation++;
    this.clearNetwork();
  }

  private clearNetwork(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.transfers.forEach((r: Receiver): void => { r.cancel(); });
    this.transfers.clear();
  }

  private resetRoom(): void {
    this.generation++;
    this.clearNetwork();
    this.messages = [];
    this.received = [];
    this.draft = '';
    this.files = [];
    this.textID = '';
    this.opened = false;
    this.busy = false;
    this.polling = false;
    this.notice = '';
    this.networkError = '';
    this.mac = 'Mac';
    this.previewId = '';
    this.showingClear = false;
    this.downloads = [];
    this.clearedThrough = 0;
    this.lastRead = 0;
    const target = this.pairing();
    if (target) {
      try {
        const prefs = preferences.getPreferencesSync(this.context(), { name: 'device-chat' });
        this.lastRead = Number(prefs.getSync('read-' + target.destination, 0));
        this.clearedThrough = Number(prefs.getSync('cleared-' + chatRoomKey(target), 0));
      } catch (_error) {
        this.notice = '未能读取本机的已读位置';
      }
    }
    this.schedule();
  }

  private schedule(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.mounted && this.foreground && this.room.length > 0) {
      this.refresh();
      this.timer = setInterval(() => { this.refresh(); }, 3500);
    }
  }

  private latest(): number {
    return this.messages.length === 0 ? this.clearedThrough : this.messages[this.messages.length - 1].sequence;
  }

  private readVisible(): void {
    const target = this.pairing();
    if (target && this.opened && this.foreground && this.latest() > this.lastRead) {
      this.lastRead = this.latest();
      try {
        const prefs = preferences.getPreferencesSync(this.context(), { name: 'device-chat' });
        prefs.putSync('read-' + target.destination, this.lastRead);
        prefs.flush().catch((): void => {});
      } catch (_error) {
        this.notice = '未能保存本机的已读位置';
      }
    }
  }

  private async refresh(): Promise<void> {
    const target = this.pairing();
    if (!target || this.polling || !this.foreground) {
      return;
    }
    const generation = this.generation;
    this.polling = true;
    const r = new Receiver(target.host, target.token);
    this.transfers.add(r);
    try {
      const page = await r.chatPage(target.installation, chatKey(this.context(), target.token), this.latest());
      if (this.generation !== generation) {
        return;
      }
      this.networkError = '';
      this.mac = page.macName || 'Mac';
      if (page.messages.length > 0) {
        this.messages = this.messages.concat(page.messages.filter((m: ChatMessage): boolean => m.sequence > this.latest()));
        this.readVisible();
        if (this.opened) {
          this.scroller.scrollEdge(Edge.Bottom);
        }
      }
      if (page.hasMore) {
        setTimeout(() => { if (this.generation === generation) { this.refresh(); } }, 0);
      }
    } catch (error) {
      if (this.generation === generation) {
        this.networkError = error instanceof Error ? error.message : '暂时无法连接到 Mac';
      }
    } finally {
      r.close();
      this.transfers.delete(r);
      if (this.generation === generation) {
        this.polling = false;
      }
    }
  }

  private snippet(): string {
    if (this.messages.length === 0) {
      return '文字和文件';
    }
    const last = this.messages[this.messages.length - 1];
    return last.kind === 'text' ? (last.text ?? '') : '文件 · ' + (last.filename ?? '');
  }

  private unread(): number {
    return this.messages.filter((m: ChatMessage): boolean => m.sender === 'mac' && m.sequence > this.lastRead).length;
  }

  private async pick(): Promise<void> {
    if (this.busy) { return; }
    const generation = this.generation;
    this.busy = true;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      const uris = await new picker.DocumentViewPicker(this.context()).select(options);
      for (const uri of uris) {
        if (this.generation !== generation) { return; }
        const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
        try {
          const info = await fileIo.stat(f.fd);
          if (!info.isFile()) { throw new Error('请选择普通文件'); }
          const size = info.size;
          if (this.generation !== generation) { return; }
          if (size > MAX_CHAT_FILE) { throw new Error('单个附件最大 128 MiB'); }
          const name = f.name || '附件';
          if (!this.files.some((item: ChatAttachment): boolean => item.uri === uri)) {
            this.files = this.files.concat([new ChatAttachment(uri, name, size)]);
          }
        } finally { fileIo.closeSync(f); }
      }
    } catch (error) {
      if (this.generation === generation) { this.notice = error instanceof Error ? error.message : '无法选择文件'; }
    } finally {
      if (this.generation === generation) { this.busy = false; }
    }
  }

  private async send(): Promise<void> {
    const target = this.pairing();
    if (!target || this.busy || (!this.draft.trim() && this.files.length === 0)) { return; }
    const generation = this.generation;
    const r = new Receiver(target.host, target.token);
    this.transfers.add(r);
    this.busy = true;
    this.notice = '正在发送…';
    try {
      const key = chatKey(this.context(), target.token);
      if (this.draft.trim()) {
        const bytes = buffer.from(this.draft, 'utf-8').length;
        if (bytes > MAX_CHAT_TEXT) { throw new Error('单条文字最大 64 KiB'); }
        if (!this.textID) { this.textID = util.generateRandomUUID(true); }
        await r.sendChat(target.installation, key, this.textID, this.draft, bytes);
        if (this.generation !== generation) { return; }
        this.draft = '';
        this.textID = '';
      }
      for (const item of this.files.slice()) {
        if (this.generation !== generation || !this.pairing()) { return; }
        const file = fileIo.openSync(item.uri, fileIo.OpenMode.READ_ONLY);
        try {
          await r.sendChat(target.installation, key, item.id, new rcp.UploadFromFile(file.fd), item.bytes, item.name);
        } finally { fileIo.closeSync(file); }
        if (this.generation !== generation) { return; }
        this.files = this.files.filter((f: ChatAttachment): boolean => f.id !== item.id);
      }
      this.notice = '已发送';
    } catch (error) {
      if (this.generation === generation) { this.notice = error instanceof Error ? error.message : '发送失败，请重试'; }
    } finally {
      r.close();
      this.transfers.delete(r);
      if (this.generation === generation) {
        this.busy = false;
        this.refresh();
      }
    }
  }

  private async fileAction(m: ChatMessage, showText: boolean): Promise<void> {
    const target = this.pairing();
    if (!target || this.busy) { return; }
    const generation = this.generation;
    const r = new Receiver(target.host, target.token);
    this.transfers.add(r);
    this.busy = true;
    const path = this.context().cacheDir + '/chat-' + util.generateRandomUUID(true);
    try {
      await r.downloadChat(target.installation, chatKey(this.context(), target.token), m.id, path);
      if (this.generation !== generation) { return; }
      if ((await fileIo.stat(path)).size !== m.bytes) { throw new Error('附件不完整，请重试'); }
      if (showText) {
        const preview = m.bytes > 0 ? await fileIo.readText(path, { length: Math.min(m.bytes, 65536) }) : '';
        if (this.generation === generation) {
          this.preview = preview + (m.bytes > 65536 ? '\n（预览前 64 KB）' : '');
          this.previewId = m.id;
        }
        return;
      }
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [m.filename || '附件'];
      const urls = await new picker.DocumentViewPicker(this.context()).save(options);
      if (urls.length === 0 || this.generation !== generation) { return; }
      const dest = fileIo.openSync(urls[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let tracked: boolean = false;
      try {
        await fileIo.copyFile(path, dest.fd);
        try {
          trackChatDownload(this.context(), chatRoomKey(target), urls[0], await fileIo.stat(dest.fd));
          tracked = true;
        } catch (_error) {
          // The exported document is already saved even if its cleanup receipt could not be written.
        }
      } finally { fileIo.closeSync(dest); }
      if (this.generation === generation) {
        this.received = this.received.concat([m.id]);
        this.notice = tracked ? '已保存到所选位置' : '已保存；此文件需在系统「文件」中管理';
      }
    } catch (error) {
      if (this.generation === generation) { this.notice = error instanceof Error ? error.message : '接收失败，请重试'; }
    } finally {
      try {
        if (fileIo.accessSync(path)) { fileIo.unlinkSync(path); }
      } catch (_error) {
        // A reclaimed cache entry must not prevent the next transfer.
      }
      r.close();
      this.transfers.delete(r);
      if (this.generation === generation) { this.busy = false; }
    }
  }

  private prepareClear(): void {
    const target = this.pairing();
    if (!target || this.busy) { return; }
    try {
      this.downloads = chatDownloads(this.context(), chatRoomKey(target));
      this.clearCount = this.messages.length;
      this.clearSequence = this.latest();
      this.clearFiles = false;
      this.showingClear = true;
    } catch (_error) {
      this.notice = '无法读取本机下载记录，请重试';
    }
  }

  private async clearConfirmed(): Promise<void> {
    const target = this.pairing();
    if (!target || this.busy || !this.showingClear) { return; }
    const owner = chatRoomKey(target);
    const generation = this.generation;
    const sequence = this.clearSequence;
    const files = this.clearFiles ? this.downloads.slice() : [];
    this.showingClear = false;
    this.busy = true;
    let failed = 0;
    try {
      const prefs = preferences.getPreferencesSync(this.context(), { name: 'device-chat' });
      prefs.putSync('cleared-' + owner, sequence);
      await prefs.flush();
      if (generation !== this.generation) { return; }
      this.clearedThrough = sequence;
      this.messages = this.messages.filter((m: ChatMessage): boolean => m.sequence > sequence);
      this.previewId = '';
      this.preview = '';
      for (const file of files) {
        try {
          if (!deleteChatDownload(this.context(), owner, file)) { failed++; }
        } catch (_error) { failed++; }
      }
      this.notice = failed > 0 ? `本机记录已清除；${failed} 个文件已变更或系统未授权删除，请在「文件」中查看` :
        (files.length > 0 ? '已清除本机记录和选中的下载文件' : '已清除本机对话记录');
    } catch (_error) {
      if (generation === this.generation) { this.notice = '未能保存清除进度，请重试'; }
    } finally {
      if (generation === this.generation) { this.busy = false; }
    }
  }

  private async copy(text: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.notice = '已复制';
    } catch (_error) { this.notice = '复制失败，请重试'; }
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Column({ space: 3 }) {
          Text('与 ' + this.mac + ' 对话').fontSize(17).fontWeight(FontWeight.Medium).fontColor('#162444')
          Text(this.snippet()).fontSize(13).fontColor('#475975').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.unread() > 0) { Text(this.unread() + ' 条未读').fontSize(13).fontColor('#2359D7') }
        Text(this.opened ? '收起' : '展开').fontSize(14).fontColor('#2359D7')
      }.width('100%').onClick(() => {
        this.opened = !this.opened;
        if (this.opened) { this.readVisible(); this.refresh(); }
      })
      if (this.opened) {
        Scroll(this.scroller) {
          Column({ space: 8 }) {
            if (this.messages.length === 0) { Text('暂无消息').fontColor('#475975') }
            ForEach(this.messages, (m: ChatMessage) => {
              Column({ space: 4 }) {
                Text((m.sender === 'mac' ? this.mac : '我') + ' · ' + new Date(m.createdAt * 1000).toLocaleTimeString())
                  .fontSize(12).fontColor('#475975')
                if (m.kind === 'text') {
                  Text(m.text ?? '').copyOption(CopyOptions.LocalDevice).padding(9)
                    .backgroundColor(m.sender === 'phone' ? '#E4EDFF' : '#F1F4F9').borderRadius(10)
                  Button('复制').type(ButtonType.Normal).fontSize(12).height(30)
                    .onClick(() => { this.copy(m.text ?? ''); })
                } else {
                  Text((m.filename ?? '附件') + ' · ' + chatSize(m.bytes)).fontSize(14)
                  if (m.sender === 'mac') {
                    Button(this.received.includes(m.id) ? '再次保存' : '接收').enabled(!this.busy)
                      .onClick(() => { this.fileAction(m, false); })
                  }
                  if (m.filename?.toLowerCase().endsWith('.txt')) {
                    Button(this.previewId === m.id ? '收起文本' : '查看文本').enabled(!this.busy)
                      .onClick(() => {
                        if (this.previewId === m.id) { this.previewId = ''; } else { this.fileAction(m, true); }
                      })
                  }
                  if (this.previewId === m.id) { Text(this.preview).copyOption(CopyOptions.LocalDevice) }
                }
              }.width('100%').alignItems(m.sender === 'mac' ? HorizontalAlign.Start : HorizontalAlign.End)
            }, (m: ChatMessage): string => m.id)
          }.width('100%')
        }.width('100%').constraintSize({ maxHeight: 265 })
        TextArea({ text: this.draft, placeholder: '输入或粘贴文字…', controller: this.editor })
          .id(CHAT_INPUT_ID)
          .enabled(!this.busy).onChange((text: string) => { this.draft = text; this.textID = ''; })
        ForEach(this.files, (file: ChatAttachment) => {
          Row() {
            Text(file.name + ' · ' + chatSize(file.bytes)).layoutWeight(1).maxLines(1)
            Button('移除').enabled(!this.busy).onClick(() => {
              this.files = this.files.filter((item: ChatAttachment): boolean => item.id !== file.id);
            })
          }.width('100%')
        }, (file: ChatAttachment): string => file.id)
        Row({ space: 8 }) {
          Button('选文件').layoutWeight(1).enabled(!this.busy).onClick(() => { this.pick(); })
          Blank().layoutWeight(1)
          Button('发送').layoutWeight(1).enabled(!this.busy && (this.draft.trim().length > 0 || this.files.length > 0))
            .onClick(() => { this.send(); })
        }.width('100%')
        Button('清除对话记录…').fontSize(13).fontColor('#A32332').backgroundColor('#FFF1F1')
          .enabled(!this.busy).onClick(() => { this.prepareClear(); })
          .bindSheet(this.showingClear, this.clearSheet(), {
            height: SheetSize.FIT_CONTENT,
            onDisappear: () => { this.showingClear = false; }
          })
        if (this.networkError || this.notice) { Text(this.networkError || this.notice).fontSize(13).fontColor('#475975') }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16).backgroundColor('#FFFFFF').borderRadius(18)
  }

  @Builder
  private clearSheet() {
    Column({ space: 14 }) {
      Text('清除对话记录').fontSize(20).fontWeight(FontWeight.Bold)
      Text(`清除这部手机与 ${this.mac} 的 ${this.clearCount} 条本机对话记录？Mac 端记录将保留。`)
      Row({ space: 6 }) {
        Checkbox().select(this.clearFiles).enabled(this.downloads.length > 0)
          .onChange((value: boolean) => { this.clearFiles = value; })
        Text(`同时删除保存到「文件」的下载文件（${this.downloads.length} 个）`).fontSize(14)
      }
      Text('此处只列出即图已登记的文件。').fontSize(12).fontColor('#475975')
      Row({ space: 12 }) {
        Button('取消').onClick(() => { this.showingClear = false; })
        Button('确认清除').backgroundColor('#A32332')
          .enabled(this.clearCount > 0 || (this.clearFiles && this.downloads.length > 0))
          .onClick(() => { this.clearConfirmed(); })
      }
    }.padding(20).width('100%')
  }
}
