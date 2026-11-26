import { Delivery, recordDelivery } from './RecentTransfers';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { loadPairing, Pairing } from './Pairing';
import { MediaFormat, imageFormat, MAX_IMAGE_BYTES } from './Protocol';
import { Receiver } from './Receiver';

export const GALLERY_PERMISSION: Permissions = 'ohos.permission.READ_IMAGEVIDEO';
const SCREENSHOTS_ALBUM: string = '/Pictures/Screenshots';

export class SyncResult {
  uploaded: number = 0;
  skipped: number = 0;
}

export class SyncCancellation {
  private cancelled: boolean = false;
  private receiver: Receiver | undefined;

  get stopped(): boolean {
    return this.cancelled;
  }

  attach(receiver: Receiver): void {
    this.receiver = receiver;
  }

  stop(): void {
    this.cancelled = true;
    this.receiver?.cancel();
  }
}

export function galleryAllowed(context: common.Context): boolean {
  const tokenId: number = context.applicationInfo.accessTokenId;
  const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  return manager.checkAccessTokenSync(tokenId, GALLERY_PERMISSION) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
}

export function isCurrentSync(context: common.Context, pairing: Pairing): boolean {
  const current: Pairing | undefined = loadPairing(context);
  return pairing.pairedAfterMs !== undefined && current?.enabled === true &&
    current.pairedAfterMs === pairing.pairedAfterMs && current.revision === pairing.revision &&
    current.destination === pairing.destination && current.host === pairing.host;
}

export async function syncScreenshots(
  context: common.Context,
  pairing: Pairing,
  cancellation: SyncCancellation,
  sending?: () => void
): Promise<SyncResult> {
  const result = new SyncResult();
  const startedMs: number | undefined = pairing.pairedAfterMs;
  if (startedMs === undefined || cancellation.stopped || !isCurrentSync(context, pairing)) {
    return result;
  }
  if (!galleryAllowed(context)) {
    throw new Error('请授权读取相册，以便查找系统截图');
  }

  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  const albumPredicates = new dataSharePredicates.DataSharePredicates();
  albumPredicates.equalTo(photoAccessHelper.AlbumKeys.ALBUM_LPATH, SCREENSHOTS_ALBUM);

  const albums: photoAccessHelper.FetchResult<photoAccessHelper.Album> = await helper.getAlbums(
    photoAccessHelper.AlbumType.SOURCE, photoAccessHelper.AlbumSubtype.SOURCE_GENERIC,
    { fetchColumns: [], predicates: albumPredicates }
  );
  let album: photoAccessHelper.Album;
  try {
    if (albums.getCount() === 0 || cancellation.stopped) {
      return result;
    }
    album = await albums.getFirstObject();
  } finally {
    albums.close();
  }
  if (cancellation.stopped) {
    return result;
  }

  const photoPredicates = new dataSharePredicates.DataSharePredicates();
  photoPredicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.IMAGE);
  photoPredicates.notEqualTo(photoAccessHelper.PhotoKeys.POSITION, photoAccessHelper.PositionType.CLOUD);
  photoPredicates.greaterThanOrEqualTo(photoAccessHelper.PhotoKeys.DATE_TAKEN, Math.floor(startedMs / 1000));
  photoPredicates.orderByDesc(photoAccessHelper.PhotoKeys.DATE_TAKEN);
  const assets: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> = await album.getAssets({
    fetchColumns: [photoAccessHelper.PhotoKeys.DATE_TAKEN_MS, photoAccessHelper.PhotoKeys.DATE_ADDED_MS],
    predicates: photoPredicates
  });

  let receiver: Receiver | undefined;
  try {
    const count: number = assets.getCount();
    for (let index = 0; index < count && !cancellation.stopped; index++) {
      const asset: photoAccessHelper.PhotoAsset = await assets.getObjectByPosition(index);
      if (cancellation.stopped) {
        break;
      }
      const date = asset.get(photoAccessHelper.PhotoKeys.DATE_TAKEN_MS);
      if (typeof date !== 'number' || !Number.isSafeInteger(date) || date <= 0) {
        result.skipped++;
        continue;
      }
      if (date <= startedMs) {
        continue;
      }

      const format: MediaFormat | undefined = imageFormat(asset.displayName);
      if (!format) {
        result.skipped++;
        continue;
      }

      const receipt: string | undefined = assetReceipt(context, pairing, asset.uri,
        asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED_MS));
      if (receipt && fileIo.accessSync(receipt)) {
        continue;
      }

      let image: ArrayBuffer;
      try {
        const file: fileIo.File = await fileIo.open(asset.uri, fileIo.OpenMode.READ_ONLY);
        image = await readImage(file, cancellation);
      } catch (_error) {
        if (cancellation.stopped) {
          break;
        }
        result.skipped++;
        continue;
      }

      if (cancellation.stopped || !isCurrentSync(context, pairing)) {
        break;
      }
      if (!receiver) {
        receiver = new Receiver(pairing.host, pairing.token);
        cancellation.attach(receiver);
        sending?.();
      }
      const alreadySent = await uploadImage(context, pairing, receiver, format, image,
        (): boolean => !cancellation.stopped && isCurrentSync(context, pairing), asset.displayName, false);
      if (alreadySent !== undefined) {
        if (receipt) {
          markReceipt(receipt);
        }
        if (!alreadySent) {
          result.uploaded++;
        }
      } else if (cancellation.stopped || !isCurrentSync(context, pairing)) {
        break;
      } else {
        result.skipped++;
      }
    }
    return result;
  } finally {
    receiver?.close();
    assets.close();
  }
}

export function assetReceipt(context: common.Context, pairing: Pairing, uri: string, added: string | number | boolean):
  string | undefined {
  const id: RegExpMatchArray | null = uri.match(/^file:\/\/media\/Photo\/(\d+)(?:\/|$)/);
  if (id && typeof added === 'number' && Number.isSafeInteger(added) && added > 0) {
    const directory: string = context.getApplicationContext().filesDir;
    // Preserve previously sent gallery receipts and avoid rereading the file on each scan.
    return `${directory}/sent-${pairing.destination}-harmony-${pairing.installation}-${id[1]}-${added}`;
  }
  return undefined;
}

export function markReceipt(path: string): void {
  const marker: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
  fileIo.closeSync(marker);
}

/** Returns true for a prior delivery, false for a new delivery, and undefined on cancellation or rejection. */
export async function uploadImage(
  context: common.Context, pairing: Pairing, receiver: Receiver, format: MediaFormat, data: ArrayBuffer,
  current: () => boolean, displayName: string, manual: boolean
): Promise<boolean | undefined> {
  const hash: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  await hash.update({ data: new Uint8Array(data) });
  const digest: cryptoFramework.DataBlob = await hash.digest();
  const hex: string = Array.from(digest.data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
  const id: string = `harmony-${pairing.installation}-image-${hex}`;
  const receipt: string = `${context.getApplicationContext().filesDir}/sent-${pairing.destination}-${id}`;
  if (fileIo.accessSync(receipt)) {
    return true;
  }
  if (!current()) {
    return undefined;
  }
  // Content-derived IDs deduplicate when the same image is sent by both gallery and picker paths.
  const filename: string = `Image-${hex.slice(0, 12)}.${format.extension}`;
  if (!(await receiver.upload(id, pairing.installation, filename, format, data))) {
    return undefined;
  }
  markReceipt(receipt);
  await recordDelivery(context, pairing,
    new Delivery(hex, displayName || filename, data.byteLength, Date.now(), manual, false), data);
  return false;
}

export async function readImage(file: fileIo.File, cancellation: SyncCancellation): Promise<ArrayBuffer> {
  try {
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    if (stat.size <= 0 || stat.size > MAX_IMAGE_BYTES) {
      throw new Error('图片为空或大于 64 MiB');
    }
    const data = new ArrayBuffer(stat.size);
    const bytes = new Uint8Array(data);
    const chunk = new ArrayBuffer(Math.min(256 * 1024, stat.size));
    let offset: number = 0;
    while (offset < stat.size) {
      if (cancellation.stopped) {
        throw new Error('同步已停止');
      }
      const length: number = Math.min(chunk.byteLength, stat.size - offset);
      const read: number = await fileIo.read(file.fd, chunk, { offset: offset, length: length });
      if (read <= 0) {
        throw new Error('图片尚未保存完整，稍后重试');
      }
      bytes.set(new Uint8Array(chunk, 0, read), offset);
      offset += read;
    }
    return data;
  } finally {
    await fileIo.close(file);
  }
}
