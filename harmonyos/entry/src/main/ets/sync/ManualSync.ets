import { Delivery, recordDelivery } from './RecentTransfers';
import { common } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { loadPairing, Pairing } from './Pairing';
import { imageFormat, MediaFormat, MAX_VIDEO_BYTES, videoFormat } from './Protocol';
import { Receiver } from './Receiver';
import { assetReceipt, galleryAllowed, markReceipt, readImage, SyncCancellation, uploadImage } from './ScreenshotSync';

export class SelectedMedia {
  constructor(
    public uri: string,
    public name: string,
    public isVideo: boolean,
    public thumbnail?: image.PixelMap,
    public receipt?: string
  ) {}
}

export class ManualResult {
  completed: string[] = [];
  error: string = '';
}

export async function selectMedia(context: common.Context, pairing: Pairing): Promise<SelectedMedia[]> {
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE;
  options.maxSelectNumber = 30;
  const picker = new photoAccessHelper.PhotoViewPicker();
  const selection: photoAccessHelper.PhotoSelectResult = await picker.select(options);
  const result: SelectedMedia[] = [];
  if (selection.photoUris.length === 0) {
    return result;
  }
  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  const canReadGallery: boolean = galleryAllowed(context);
  for (const uri of new Set(selection.photoUris)) {
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
    const name: string = uri.split('/').pop() ?? '';
    const selected = new SelectedMedia(uri, name, videoFormat(name) !== undefined);
    let assets: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | undefined;
    try {
      assets = await helper.getAssets({
        fetchColumns: canReadGallery ? [photoAccessHelper.PhotoKeys.DATE_ADDED_MS] : [],
        predicates: predicates
      });
      if (assets.getCount() > 0) {
        const asset: photoAccessHelper.PhotoAsset = await assets.getFirstObject();
        selected.name = asset.displayName;
        selected.isVideo = asset.photoType === photoAccessHelper.PhotoType.VIDEO;
        if (canReadGallery && !selected.isVideo) {
          selected.receipt = assetReceipt(context, pairing, asset.uri, asset.get(photoAccessHelper.PhotoKeys.DATE_ADDED_MS));
        }
        selected.thumbnail = await asset.getThumbnail({ width: 224, height: 224 });
      }
    } catch (_error) {
      // The picker grant can still allow a direct read even if preview metadata is unavailable.
    } finally {
      assets?.close();
    }
    result.push(selected);
  }
  return result;
}

export async function sendSelection(
  context: common.Context, pairing: Pairing, selection: SelectedMedia[], cancellation: SyncCancellation
): Promise<ManualResult> {
  const result = new ManualResult();
  let receiver: Receiver | undefined;
  const isCurrent = (): boolean => {
    const current: Pairing | undefined = loadPairing(context);
    return !cancellation.stopped && current?.destination === pairing.destination && current.host === pairing.host;
  };
  try {
    for (const item of selection) {
      if (!isCurrent()) {
        break;
      }
      const video: MediaFormat | undefined = videoFormat(item.name);
      if (item.isVideo || video !== undefined) {
        if (!video) {
          result.error = '视频仅支持 MP4、MOV 或 M4V 格式';
          continue;
        }
        if (!receiver) {
          receiver = new Receiver(pairing.host, pairing.token);
          cancellation.attach(receiver);
        }
        const error: string | undefined = await sendVideo(context, pairing, receiver, item, video, isCurrent);
        if (error === undefined) {
          result.completed.push(item.uri);
        } else if (!isCurrent()) {
          break;
        } else {
          result.error = error;
        }
        continue;
      }
      if (item.receipt && fileIo.accessSync(item.receipt)) {
        result.completed.push(item.uri);
        continue;
      }
      let bytes: ArrayBuffer;
      try {
        // The system picker grants read-only URI access when the user confirms from our page.
        const file: fileIo.File = fileIo.openSync(item.uri, fileIo.OpenMode.READ_ONLY);
        bytes = await readImage(file, cancellation);
      } catch (_error) {
        if (cancellation.stopped) {
          break;
        }
        result.error = '有图片无法读取或超过 64 MiB';
        continue;
      }
      const format: MediaFormat | undefined = imageFormat(item.name) ?? identifyImage(bytes);
      if (!format) {
        result.error = '有图片的格式暂不支持';
        continue;
      }
      if (!isCurrent()) {
        break;
      }
      if (!receiver) {
        receiver = new Receiver(pairing.host, pairing.token);
        cancellation.attach(receiver);
      }
      const sent = await uploadImage(context, pairing, receiver, format, bytes, isCurrent, item.name, true);
      if (sent !== undefined) {
        result.completed.push(item.uri);
      } else if (!isCurrent()) {
        break;
      } else {
        result.error = 'Mac 无法保存部分图片';
      }
    }
  } catch (error) {
    if (!cancellation.stopped) {
      result.error = error instanceof Error ? error.message : '暂时无法发送，请稍后重试';
    }
  } finally {
    receiver?.close();
  }
  return result;
}

async function sendVideo(
  context: common.Context, pairing: Pairing, receiver: Receiver, item: SelectedMedia, format: MediaFormat,
  isCurrent: () => boolean
): Promise<string | undefined> {
  let file: fileIo.File | undefined;
  try {
    let size: number;
    let hex: string;
    try {
      // Keep the picker-granted descriptor open until the native HTTP upload has finished.
      file = fileIo.openSync(item.uri, fileIo.OpenMode.READ_ONLY);
      size = (await fileIo.stat(file.fd)).size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > MAX_VIDEO_BYTES) {
        return '视频为空或超过 512 MiB';
      }
      hex = await videoFingerprint(file.fd, size, isCurrent);
      fileIo.lseek(file.fd, 0);
    } catch (_error) {
      return '无法读取已选视频';
    }
    if (!isCurrent()) {
      return '同步已停止';
    }
    const id: string = `harmony-${pairing.installation}-video-${hex}`;
    const receipt: string = `${context.getApplicationContext().filesDir}/sent-${pairing.destination}-${id}`;
    if (fileIo.accessSync(receipt)) {
      return undefined;
    }
    const filename: string = `Video-${hex.slice(0, 12)}.${format.extension}`;
    if (!(await receiver.uploadVideo(id, pairing.installation, filename, format, file.fd, size))) {
      return 'Mac 无法保存该视频，请确认接收端已更新且支持该格式';
    }
    markReceipt(receipt);
    await recordDelivery(context, pairing,
      new Delivery(hex, item.name || filename, size, Date.now(), true, true), undefined, item.thumbnail);
    return undefined;
  } finally {
    if (file) {
      await fileIo.close(file);
    }
  }
}

async function videoFingerprint(fd: number, size: number, isCurrent: () => boolean): Promise<string> {
  const hash: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
  const chunk = new ArrayBuffer(Math.min(256 * 1024, size));
  let offset: number = 0;
  while (offset < size) {
    if (!isCurrent()) {
      throw new Error('同步已停止');
    }
    const length: number = Math.min(chunk.byteLength, size - offset);
    const read: number = await fileIo.read(fd, chunk, { length: length });
    if (read <= 0) {
      throw new Error('视频读取中断');
    }
    await hash.update({ data: new Uint8Array(chunk, 0, read) });
    offset += read;
  }
  const digest: cryptoFramework.DataBlob = await hash.digest();
  return Array.from(digest.data, (byte: number): string => byte.toString(16).padStart(2, '0')).join('');
}

function identifyImage(data: ArrayBuffer): MediaFormat | undefined {
  if (data.byteLength < 12) {
    return undefined;
  }
  const bytes = new DataView(data);
  if (bytes.getUint32(0) === 0x89504E47) {
    return imageFormat('.png');
  }
  if (bytes.getUint16(0) === 0xFFD8) {
    return imageFormat('.jpg');
  }
  if (bytes.getUint32(0) === 0x52494646 && bytes.getUint32(8) === 0x57454250) {
    return imageFormat('.webp');
  }
  if (bytes.getUint32(4) === 0x66747970) {
    const brand: number = bytes.getUint32(8);
    if (brand === 0x68656963 || brand === 0x68656978) {
      return imageFormat('.heic');
    }
    if (brand === 0x6D696631 || brand === 0x6D736631) {
      return imageFormat('.heif');
    }
  }
  return undefined;
}
