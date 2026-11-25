import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Pairing } from './Pairing';

export interface ChatDownload {
  receipt: string;
  owner: string;
  uri: string;
  inode: string;
  modified: string;
  bytes: number;
}

export function chatRoomKey(target: Pairing): string {
  return target.token + '-' + target.installation;
}

function receipts(context: common.Context): string {
  return context.filesDir + '/chat-downloads.json';
}

function read(context: common.Context): ChatDownload[] {
  try {
    return JSON.parse(fileIo.readTextSync(receipts(context))) as ChatDownload[];
  } catch (error) {
    if ((error as BusinessError).code === 13900002) { return []; }
    throw error;
  }
}

function store(context: common.Context, entries: ChatDownload[]): void {
  try {
    const path = receipts(context);
    const content = JSON.stringify(entries);
    const file = fileIo.openSync(path + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
    try {
      if (fileIo.writeSync(file.fd, content) !== buffer.byteLength(content, 'utf-8')) {
        throw new Error('无法记录下载文件');
      }
      fileIo.fsyncSync(file.fd);
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(path + '.tmp', path);
  } catch (_error) { throw new Error('无法保存本机下载记录'); }
}

function modified(info: fileIo.Stat): string {
  return info.mtimeNs !== undefined ? info.mtimeNs.toString() : info.mtime.toString();
}

export function trackChatDownload(context: common.Context, owner: string, uri: string, info: fileIo.Stat): void {
  const entries = read(context).filter((f: ChatDownload): boolean => f.uri !== uri);
  entries.push({ receipt: util.generateRandomUUID(true), owner: owner, uri: uri, inode: info.ino.toString(),
    modified: modified(info), bytes: info.size });
  store(context, entries);
}

export function chatDownloads(context: common.Context, owner: string): ChatDownload[] {
  return read(context).filter((f: ChatDownload): boolean => f.owner === owner);
}

export function deleteChatDownload(context: common.Context, owner: string, confirmed: ChatDownload): boolean {
  const entries = read(context);
  const entry = entries.find((f: ChatDownload): boolean => f.owner === owner && f.receipt === confirmed.receipt);
  if (!entry) { return true; }
  let file: fileIo.File | undefined;
  try {
    // Ask the provider for only the exact document originally returned by the save picker.
    file = fileIo.openSync(entry.uri, fileIo.OpenMode.READ_ONLY);
    const info = fileIo.lstatSync(file.path);
    if (!info.isFile() || info.isSymbolicLink() || info.ino.toString() !== entry.inode ||
      info.size !== entry.bytes || modified(info) !== entry.modified) {
      return false;
    }
    fileIo.unlinkSync(file.path);
  } catch (error) {
    if ((error as BusinessError).code !== 13900002) { return false; }
  } finally {
    if (file) {
      try { fileIo.closeSync(file); } catch (_error) { /* The provider may have closed the unlinked file. */ }
    }
  }
  store(context, entries.filter((f: ChatDownload): boolean => f.receipt !== entry.receipt));
  return true;
}
