import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export const MAX_CHAT_FILE: number = 128 * 1024 * 1024;
export const MAX_CHAT_TEXT: number = 64 * 1024;

export interface ChatMessage {
  id: string;
  sequence: number;
  createdAt: number;
  sender: string;
  kind: string;
  text?: string;
  filename?: string;
  bytes: number;
}

export interface ChatPage {
  messages: ChatMessage[];
  hasMore: boolean;
  macName: string;
}

export class ChatAttachment {
  id: string = util.generateRandomUUID(true);
  constructor(public uri: string, public name: string, public bytes: number) {}
}

export function chatKey(context: common.Context, token: string): string {
  const path: string = context.filesDir + '/chat-key-' + token;
  try {
    if (fileIo.accessSync(path)) {
      const saved: string = fileIo.readTextSync(path);
      if (!/^[0-9a-f]{64}$/.test(saved)) {
        throw new Error('无法读取本机对话凭据');
      }
      return saved;
    }
    const key: string = buffer.from(cryptoFramework.createRandom().generateRandomSync(32).data).toString('hex');
    const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    try {
      if (fileIo.writeSync(file.fd, key) !== key.length) {
        throw new Error('无法保存对话凭据');
      }
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(path + '.tmp', path);
    return key;
  } catch (_error) {
    throw new Error('无法读写本机对话凭据，请重试');
  }
}

export function chatSize(bytes: number): string {
  if (bytes < 1024) {
    return bytes + ' B';
  }
  if (bytes < 1048576) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return (bytes / 1048576).toFixed(1) + ' MB';
}
