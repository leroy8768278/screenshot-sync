import { KeyboardAvoidMode } from '@kit.ArkUI';
import { ChatSession } from '../sync/ChatSession';
import { ChatAttachment, ChatMessage, chatSize } from '../sync/ChatTypes';

const BLUE: string = '#2359D7';
const INK: string = '#162444';
const MUTED: string = '#475975';
const CHAT_INPUT_ID: string = 'chat-message-input';
const DISMISS_KEYBOARD: string = 'dismiss-chat-keyboard';

@Component
export struct ChatEntry {
  @ObjectLink session: ChatSession;
  open: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('与 ' + this.session.mac + ' 对话').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor(INK).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.session.snippet()).fontSize(13).fontColor(MUTED).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.session.unread() > 0) {
          Text(this.session.unread() + ' 条未读').fontSize(13).fontColor(BLUE)
        }
        Text('›').fontSize(24).fontColor(MUTED).accessibilityLevel('no')
      }.width('100%').padding(16)
    }.width('100%').height('auto').backgroundColor(Color.White).borderRadius(18).onClick(this.open)
  }
}

@Component
export struct ChatPage {
  @ObjectLink session: ChatSession;
  private readonly editor: TextAreaController = new TextAreaController();
  private readonly history: Scroller = new Scroller();
  private followLatest: boolean = true;
  private previousKeyboardMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;

  aboutToAppear(): void {
    const ui = this.getUIContext();
    this.previousKeyboardMode = ui.getKeyboardAvoidMode();
    ui.setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
  }

  aboutToDisappear(): void {
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
  }

  build() {
    NavDestination() {
      Column() {
        Scroll(this.history) {
          Column({ space: 14 }) {
            if (this.session.messages.length === 0) {
              Text('暂无消息').fontSize(14).fontColor(MUTED).padding(20)
            }
            ForEach(this.session.messages, (m: ChatMessage) => {
              this.message(m)
            }, (m: ChatMessage): string => m.id)
          }
          .padding(16).width('100%')
          .onAreaChange(() => { if (this.followLatest) { this.history.scrollEdge(Edge.Bottom); } })
        }
        .width('100%').layoutWeight(1)
        .onScrollStop(() => { this.followLatest = this.history.isAtEnd(); })

        this.composer()
      }
      .height('100%').width('100%').backgroundColor('#F3F6FC')
      .parallelGesture(TapGesture().tag(DISMISS_KEYBOARD).onAction(() => { this.editor.stopEditing(); }))
      .onTouchTestDone((_event: BaseGestureEvent, recognizers: GestureRecognizer[]) => {
        if (recognizers.some((r: GestureRecognizer): boolean => r.getEventTargetInfo().getId() === CHAT_INPUT_ID)) {
          recognizers.find((r: GestureRecognizer): boolean => r.getTag() === DISMISS_KEYBOARD)?.preventBegin();
        }
      })
      .bindSheet(this.session.showingClear, this.clearSheet(), {
        height: SheetSize.FIT_CONTENT,
        onDisappear: () => { this.session.showingClear = false; }
      })
    }
    .title('与 ' + this.session.mac + ' 对话')
    .menus(this.actions())
    .onShown(() => { this.session.setPageVisible(true); })
    .onHidden(() => { this.session.setPageVisible(false); })
  }

  @Builder
  private actions() {
    Button('清除对话记录').fontSize(13).fontColor('#A32332').backgroundColor('#FFF1F1')
      .enabled(!this.session.busy)
      .onClick(() => { this.editor.stopEditing(); this.session.prepareClear(); })
  }

  @Builder
  private message(m: ChatMessage) {
    Column({ space: 4 }) {
      Text((m.sender === 'mac' ? this.session.mac : '我') + ' · ' + new Date(m.createdAt * 1000).toLocaleTimeString())
        .fontSize(12).fontColor(MUTED)
      if (m.kind === 'text') {
        Text(m.text ?? '').copyOption(CopyOptions.LocalDevice).padding(10).fontColor(INK)
          .backgroundColor(m.sender === 'phone' ? '#E4EDFF' : '#FFFFFF').borderRadius(10)
        Button('复制').fontSize(12).height(30).backgroundColor(Color.Transparent).fontColor(BLUE)
          .onClick(() => { this.session.copy(m.text ?? ''); })
      } else {
        Text((m.filename ?? '附件') + ' · ' + chatSize(m.bytes)).fontSize(14)
        if (m.sender === 'mac') {
          Button(this.session.received.includes(m.id) ? '再次保存' : '接收').enabled(!this.session.busy)
            .onClick(() => { this.session.fileAction(m, false); })
        }
        if (m.filename?.toLowerCase().endsWith('.txt')) {
          Button(this.session.previewId === m.id ? '收起文本' : '查看文本').enabled(!this.session.busy)
            .onClick(() => {
              if (this.session.previewId === m.id) { this.session.previewId = ''; } else { this.session.fileAction(m, true); }
            })
        }
        if (this.session.previewId === m.id) { Text(this.session.preview).copyOption(CopyOptions.LocalDevice) }
      }
    }.width('100%').alignItems(m.sender === 'mac' ? HorizontalAlign.Start : HorizontalAlign.End)
  }

  @Builder
  private composer() {
    Column({ space: 8 }) {
      if (this.session.networkError || this.session.notice) {
        Text(this.session.networkError || this.session.notice).fontSize(13).fontColor(MUTED)
      }
      if (this.session.files.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.session.files, (file: ChatAttachment) => {
              Row({ space: 4 }) {
                Text(file.name + ' · ' + chatSize(file.bytes)).fontSize(12).maxLines(1)
                  .constraintSize({ maxWidth: 160 }).textOverflow({ overflow: TextOverflow.Ellipsis })
                Button('移除').height(30).fontSize(12).enabled(!this.session.busy)
                  .onClick(() => { this.session.removeAttachment(file.id); })
              }
            }, (file: ChatAttachment): string => file.id)
          }
        }.scrollable(ScrollDirection.Horizontal).width('100%')
      }
      TextArea({ text: this.session.draft, placeholder: '输入或粘贴文字', controller: this.editor })
        .id(CHAT_INPUT_ID).maxLines(3).constraintSize({ minHeight: 44, maxHeight: 96 })
        .enabled(!this.session.busy).onChange((text: string) => { this.session.updateDraft(text); })
      Row() {
        Button('选文件').backgroundColor('#EAF0FF').fontColor(INK).enabled(!this.session.busy)
          .onClick(() => { this.session.pick(); })
        Blank().layoutWeight(1)
        Button('发送').backgroundColor(BLUE)
          .enabled(!this.session.busy && (this.session.draft.trim().length > 0 || this.session.files.length > 0))
          .onClick(() => { this.followLatest = true; this.session.send(); })
      }.width('100%')
    }.width('100%').padding(12).backgroundColor(Color.White)
  }

  @Builder
  private clearSheet() {
    Column({ space: 14 }) {
      Text('清除对话记录').fontSize(20).fontWeight(FontWeight.Bold)
      Text(`清除这部手机与 ${this.session.mac} 的 ${this.session.clearCount} 条本机对话记录？Mac 端记录将保留。`)
      Row({ space: 6 }) {
        Checkbox().select(this.session.clearFiles).enabled(this.session.downloads.length > 0)
          .onChange((value: boolean) => { this.session.clearFiles = value; })
        Text(`同时删除保存到「文件」的下载文件（${this.session.downloads.length} 个）`).fontSize(14)
      }
      Text('此处只列出即图已登记的文件。').fontSize(12).fontColor(MUTED)
      Row({ space: 12 }) {
        Button('取消').onClick(() => { this.session.showingClear = false; })
        Button('确认清除').backgroundColor('#A32332')
          .enabled(this.session.clearCount > 0 || (this.session.clearFiles && this.session.downloads.length > 0))
          .onClick(() => { this.session.clearConfirmed(); })
      }
    }.padding(20).width('100%')
  }
}
