import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { loadPairing, Pairing } from './Pairing';
import { ImageFormat, imageFormat, MAX_IMAGE_BYTES } from './Protocol';
import { Receiver } from './Receiver';

export const GALLERY_PERMISSION: Permissions = 'ohos.permission.READ_IMAGEVIDEO';
const SCREENSHOTS_ALBUM: string = '/Pictures/Screenshots';

export class SyncResult {
  uploaded: number = 0;
  skipped: number = 0;
}

export function galleryAllowed(context: common.Context): boolean {
  const tokenId: number = context.applicationInfo.accessTokenId;
  const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
  return manager.checkAccessTokenSync(tokenId, GALLERY_PERMISSION) === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
}

export async function syncScreenshots(
  context: common.Context,
  pairing: Pairing,
  canContinue: () => boolean
): Promise<SyncResult> {
  if (!galleryAllowed(context)) {
    throw new Error('请授权读取相册，以便查找系统截图');
  }

  const result = new SyncResult();
  const receiptFolder: string = context.getApplicationContext().filesDir;
  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  const albumPredicates = new dataSharePredicates.DataSharePredicates();
  albumPredicates.equalTo(photoAccessHelper.AlbumKeys.ALBUM_LPATH, SCREENSHOTS_ALBUM);

  const albums: photoAccessHelper.FetchResult<photoAccessHelper.Album> = await helper.getAlbums(
    photoAccessHelper.AlbumType.SOURCE, photoAccessHelper.AlbumSubtype.SOURCE_GENERIC,
    { fetchColumns: [], predicates: albumPredicates }
  );
  let album: photoAccessHelper.Album;
  try {
    if (albums.getCount() === 0 || !canContinue()) {
      return result;
    }
    album = await albums.getFirstObject();
  } finally {
    albums.close();
  }

  const photoPredicates = new dataSharePredicates.DataSharePredicates();
  photoPredicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_TYPE, photoAccessHelper.PhotoType.IMAGE);
  photoPredicates.notEqualTo(photoAccessHelper.PhotoKeys.POSITION, photoAccessHelper.PositionType.CLOUD);
  if (pairing.sinceMs > 0) {
    photoPredicates.greaterThanOrEqualTo(photoAccessHelper.PhotoKeys.DATE_ADDED, Math.floor(pairing.sinceMs / 1000));
  }
  photoPredicates.orderByAsc(photoAccessHelper.PhotoKeys.DATE_ADDED);
  const assets: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> = await album.getAssets({
    fetchColumns: [photoAccessHelper.PhotoKeys.DATE_ADDED, photoAccessHelper.PhotoKeys.DATE_ADDED_MS],
    predicates: photoPredicates
  });

  let receiver: Receiver | undefined;
  try {
    const count: number = assets.getCount();
    for (let index = 0; index < count && canContinue(); index++) {
      const asset: photoAccessHelper.PhotoAsset = await assets.getObjectByPosition(index);
      const date = asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED_MS);
      if (typeof date !== 'number' || !Number.isSafeInteger(date) || date <= 0) {
        result.skipped++;
        continue;
      }
      if (date < pairing.sinceMs) {
        continue;
      }

      const idMatch: RegExpMatchArray | null = asset.uri.match(/^file:\/\/media\/Photo\/(\d+)(?:\/|$)/);
      const format: ImageFormat | undefined = imageFormat(asset.displayName);
      if (!idMatch || !format) {
        result.skipped++;
        continue;
      }

      const id: string = `harmony-${pairing.installation}-${idMatch[1]}-${date}`;
      const receipt: string = `${receiptFolder}/sent-${pairing.destination}-${id}`;
      if (fileIo.accessSync(receipt)) {
        continue;
      }

      let image: ArrayBuffer;
      try {
        image = await readImage(asset.uri);
      } catch (_error) {
        result.skipped++;
        continue;
      }

      const current: Pairing | undefined = loadPairing(context);
      if (!canContinue() || !current || !current.enabled || current.destination !== pairing.destination ||
        current.host !== pairing.host) {
        break;
      }
      if (!receiver) {
        receiver = new Receiver(pairing.host, pairing.token);
      }
      const filename: string = `Screenshot-${date}-${idMatch[1]}.${format.extension}`;
      if (await receiver.upload(id, filename, format, image)) {
        // A retry after a crash may send the same ID. The Mac commits each ID only once.
        const marker: fileIo.File = fileIo.openSync(receipt, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
        fileIo.closeSync(marker);
        result.uploaded++;
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

async function readImage(uri: string): Promise<ArrayBuffer> {
  const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat: fileIo.Stat = await fileIo.stat(file.fd);
    if (stat.size <= 0 || stat.size > MAX_IMAGE_BYTES) {
      throw new Error('截图为空或大于 64 MiB');
    }
    const data = new ArrayBuffer(stat.size);
    const bytes = new Uint8Array(data);
    const chunk = new ArrayBuffer(Math.min(256 * 1024, stat.size));
    let offset: number = 0;
    while (offset < stat.size) {
      const length: number = Math.min(chunk.byteLength, stat.size - offset);
      const read: number = await fileIo.read(file.fd, chunk, { offset: offset, length: length });
      if (read <= 0) {
        throw new Error('截图仍在写入，稍后重试');
      }
      bytes.set(new Uint8Array(chunk, 0, read), offset);
      offset += read;
    }
    return data;
  } finally {
    await fileIo.close(file);
  }
}
