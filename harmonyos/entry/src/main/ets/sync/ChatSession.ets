import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ChatAttachment, ChatMessage, chatKey, MAX_CHAT_FILE, MAX_CHAT_TEXT } from './ChatTypes';
import { ChatDownload, chatDownloads, chatRoomKey, deleteChatDownload, trackChatDownload } from './ChatDownloads';
import { loadPairing, Pairing } from './Pairing';
import { macDisplayName } from './MacProfile';
import { Receiver } from './Receiver';

@Observed
export class ChatSession {
  private foreground: boolean = false;
  private visible: boolean = false;
  messages: ChatMessage[] = [];
  private lastRead: number = 0;
  mac: string = 'Mac';
  draft: string = '';
  files: ChatAttachment[] = [];
  busy: boolean = false;
  notice: string = '';
  networkError: string = '';
  received: string[] = [];
  previewId: string = '';
  preview: string = '';
  showingClear: boolean = false;
  clearFiles: boolean = false;
  clearCount: number = 0;
  downloads: ChatDownload[] = [];
  private clearSequence: number = 0;
  private clearedThrough: number = 0;
  private timer: number = -1;
  private generation: number = 0;
  private polling: boolean = false;
  private textID: string = '';
  private transfers: Set<Receiver> = new Set();

  readonly room: string;
  private readonly context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext, room: string) {
    this.context = context;
    this.room = room;
    const target = this.pairing();
    if (target) {
      this.mac = target.mac ? macDisplayName(target.mac) : 'Mac';
      try {
        const prefs = preferences.getPreferencesSync(context, { name: 'device-chat' });
        this.lastRead = Number(prefs.getSync('read-' + target.destination, 0));
        this.clearedThrough = Number(prefs.getSync('cleared-' + chatRoomKey(target), 0));
      } catch (_error) {
        this.notice = '未能读取本机的已读位置';
      }
    }
  }

  private pairing(): Pairing | undefined {
    const target = loadPairing(this.context);
    if (target && target.pairedAfterMs !== undefined && target.destination + ':' + target.host === this.room) {
      return target;
    }
    return undefined;
  }

  setPageVisible(visible: boolean): void {
    this.visible = visible;
    if (visible) {
      this.readVisible();
      this.refresh();
    } else {
      this.showingClear = false;
      this.previewId = '';
    }
  }

  close(): void {
    this.foreground = false;
    this.visible = false;
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

  setForeground(value: boolean): void {
    if (this.foreground === value) { return; }
    this.foreground = value;
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.foreground) {
      this.readVisible();
      this.refresh();
      this.timer = setInterval(() => { this.refresh(); }, 3500);
    }
  }

  private latest(): number {
    return this.messages.length === 0 ? this.clearedThrough : this.messages[this.messages.length - 1].sequence;
  }

  private readVisible(): void {
    const target = this.pairing();
    if (target && this.visible && this.foreground && this.latest() > this.lastRead) {
      this.lastRead = this.latest();
      try {
        const prefs = preferences.getPreferencesSync(this.context, { name: 'device-chat' });
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
      const page = await r.chatPage(target.installation, chatKey(this.context, target.token), this.latest());
      if (this.generation !== generation) {
        return;
      }
      this.networkError = '';
      this.mac = page.macName || 'Mac';
      if (page.messages.length > 0) {
        this.messages = this.messages.concat(page.messages.filter((m: ChatMessage): boolean => m.sequence > this.latest()));
        this.readVisible();
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

  snippet(): string {
    if (this.messages.length === 0) {
      return '文字和文件';
    }
    const last = this.messages[this.messages.length - 1];
    return last.kind === 'text' ? (last.text ?? '') : '文件 · ' + (last.filename ?? '');
  }

  unread(): number {
    return this.messages.filter((m: ChatMessage): boolean => m.sender === 'mac' && m.sequence > this.lastRead).length;
  }

  updateDraft(text: string): void {
    this.draft = text;
    this.textID = '';
  }

  removeAttachment(id: string): void {
    this.files = this.files.filter((item: ChatAttachment): boolean => item.id !== id);
  }

  async pick(): Promise<void> {
    if (this.busy) { return; }
    const generation = this.generation;
    this.busy = true;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
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

  async send(): Promise<void> {
    const target = this.pairing();
    if (!target || this.busy || (!this.draft.trim() && this.files.length === 0)) { return; }
    const generation = this.generation;
    const r = new Receiver(target.host, target.token);
    this.transfers.add(r);
    this.busy = true;
    this.notice = '正在发送…';
    try {
      const key = chatKey(this.context, target.token);
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

  async fileAction(m: ChatMessage, showText: boolean): Promise<void> {
    const target = this.pairing();
    if (!target || this.busy) { return; }
    const generation = this.generation;
    const r = new Receiver(target.host, target.token);
    this.transfers.add(r);
    this.busy = true;
    const path = this.context.cacheDir + '/chat-' + util.generateRandomUUID(true);
    try {
      await r.downloadChat(target.installation, chatKey(this.context, target.token), m.id, path);
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
      const urls = await new picker.DocumentViewPicker(this.context).save(options);
      if (urls.length === 0 || this.generation !== generation) { return; }
      const dest = fileIo.openSync(urls[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      let tracked: boolean = false;
      try {
        await fileIo.copyFile(path, dest.fd);
        try {
          trackChatDownload(this.context, chatRoomKey(target), urls[0], await fileIo.stat(dest.fd));
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

  prepareClear(): void {
    const target = this.pairing();
    if (!target || this.busy) { return; }
    try {
      this.downloads = chatDownloads(this.context, chatRoomKey(target));
      this.clearCount = this.messages.length;
      this.clearSequence = this.latest();
      this.clearFiles = false;
      this.showingClear = true;
    } catch (_error) {
      this.notice = '无法读取本机下载记录，请重试';
    }
  }

  async clearConfirmed(): Promise<void> {
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
      const prefs = preferences.getPreferencesSync(this.context, { name: 'device-chat' });
      prefs.putSync('cleared-' + owner, sequence);
      await prefs.flush();
      if (generation !== this.generation) { return; }
      this.clearedThrough = sequence;
      this.messages = this.messages.filter((m: ChatMessage): boolean => m.sequence > sequence);
      this.previewId = '';
      this.preview = '';
      for (const file of files) {
        try {
          if (!deleteChatDownload(this.context, owner, file)) { failed++; }
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

  async copy(text: string): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      this.notice = '已复制';
    } catch (_error) { this.notice = '复制失败，请重试'; }
  }
}
