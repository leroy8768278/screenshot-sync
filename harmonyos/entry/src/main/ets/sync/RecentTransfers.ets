import { common } from '@kit.AbilityKit';
import { buffer, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Pairing } from './Pairing';

const LIMIT: number = 8;

export class Delivery {
  constructor(public id: string, public name: string, public bytes: number, public time: number,
    public manual: boolean, public video: boolean, public thumbnail: string = '') {}
}

function directory(context: common.Context, pairing: Pairing): string {
  // The verified receiver token survives address changes and scanning the same Mac again.
  const hash = cryptoFramework.createMd('SHA256');
  hash.updateSync({ data: Uint8Array.from(pairing.token.split(''), (c: string): number => c.charCodeAt(0)) });
  return context.getApplicationContext().filesDir + '/recent-' + buffer.from(hash.digestSync().data).toString('hex');
}

// Immutable per-item receipts allow the foreground and scheduled worker to publish independently.
function files(dir: string): string[] {
  return fileIo.listFileSync(dir).filter((name: string): boolean =>
    /^\d{13}-[a-f0-9]{64}\.json$/.test(name)).sort().reverse();
}

export function recentTransfers(context: common.Context, pairing: Pairing): Delivery[] {
  const result: Delivery[] = [];
  try {
    const dir = directory(context, pairing);
    if (!fileIo.accessSync(dir)) { return result; }
    for (const name of files(dir)) {
      try {
        const row = JSON.parse(fileIo.readTextSync(dir + '/' + name)) as Delivery;
        if (row.id && typeof row.name === 'string' && Number.isSafeInteger(row.time) &&
          !result.some((item: Delivery): boolean => item.id === row.id)) {
          result.push(row);
        }
      } catch (_error) {
        // A concurrent write can trim a receipt before it is read.
      }
      if (result.length >= LIMIT) { break; }
    }
  } catch (_error) {}
  return result;
}

export function lastDelivery(context: common.Context, pairing: Pairing, rows: Delivery[]): number {
  const latest = rows.length ? rows[0].time : 0;
  try {
    const path = directory(context, pairing) + '/last-delivery';
    if (fileIo.accessSync(path)) {
      const saved = Number(fileIo.readTextSync(path));
      if (Number.isSafeInteger(saved)) { return Math.max(latest, saved); }
    }
  } catch (_error) {}
  return latest;
}

export function clearRecentTransfers(context: common.Context, pairing: Pairing, visible: Delivery[]): boolean {
  try {
    const dir = directory(context, pairing);
    if (!visible.length || !fileIo.accessSync(dir)) { return true; }
    // Preserve the pairing card's delivery time independently of the deleted receipts.
    const timestamp = lastDelivery(context, pairing, visible).toString();
    const temporary = dir + '/' + util.generateRandomUUID(true) + '.tmp';
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    try {
      try {
        if (fileIo.writeSync(file.fd, timestamp) !== timestamp.length) { throw new Error('保存送达时间失败'); }
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(temporary, dir + '/last-delivery');
    } finally {
      if (fileIo.accessSync(temporary)) { fileIo.unlinkSync(temporary); }
    }
    for (const name of files(dir)) {
      const time = Number(name.slice(0, 13));
      const id = name.slice(14, -5);
      // Also remove superseded receipts for the same image while preserving newer arrivals.
      if (!visible.some((row: Delivery): boolean => row.id === id && time <= row.time)) { continue; }
      try {
        fileIo.unlinkSync(dir + '/' + name);
      } catch (error) {
        if (fileIo.accessSync(dir + '/' + name)) { throw error; }
      }
    }
    return true;
  } catch (_error) {
    return false;
  }
}

async function thumbnail(data?: ArrayBuffer, preview?: image.PixelMap): Promise<string> {
  let source: image.ImageSource | undefined;
  let reduced: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  try {
    if (data && !preview) {
      source = image.createImageSource(data);
      const info = await source.getImageInfo();
      const ratio = Math.min(1, 112 / Math.max(info.size.width, info.size.height));
      reduced = await source.createPixelMap({ desiredSize: {
        width: Math.max(1, Math.round(info.size.width * ratio)),
        height: Math.max(1, Math.round(info.size.height * ratio))
      } });
    }
    const bitmap = preview ?? reduced;
    if (!bitmap) { return ''; }
    packer = image.createImagePacker();
    const jpeg = await packer.packToData(bitmap, { format: 'image/jpeg', quality: 62 });
    if (jpeg.byteLength > 65536) { return ''; }
    return 'data:image/jpeg;base64,' + buffer.from(jpeg).toString('base64');
  } catch (_error) {
    return '';
  } finally {
    if (packer) { await packer.release().catch((): void => {}); }
    if (reduced) { await reduced.release().catch((): void => {}); }
    if (source) { await source.release().catch((): void => {}); }
  }
}

export async function recordDelivery(context: common.Context, pairing: Pairing, row: Delivery,
  data?: ArrayBuffer, preview?: image.PixelMap): Promise<void> {
  let staging: string = '';
  try {
    const dir = directory(context, pairing);
    row.thumbnail = await thumbnail(data, preview);
    if (!fileIo.accessSync(dir)) {
      try { fileIo.mkdirSync(dir, true); } catch (error) {
        if (!fileIo.accessSync(dir)) { throw error; }
      }
    }
    staging = dir + '/' + util.generateRandomUUID(true) + '.tmp';
    const file = fileIo.openSync(staging, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    try {
      const json = JSON.stringify(row);
      if (fileIo.writeSync(file.fd, json) !== buffer.byteLength(json, 'utf-8')) { return; }
    } finally { fileIo.closeSync(file); }
    fileIo.renameSync(staging, dir + '/' + row.time + '-' + row.id + '.json');
    staging = '';
    for (const old of files(dir).slice(LIMIT)) {
      try { fileIo.unlinkSync(dir + '/' + old); } catch (_error) {}
    }
  } catch (_error) {
    // Presentation history must never turn an acknowledged upload into a failed transfer.
  } finally {
    if (staging) { try { fileIo.unlinkSync(staging); } catch (_error) {} }
  }
}
