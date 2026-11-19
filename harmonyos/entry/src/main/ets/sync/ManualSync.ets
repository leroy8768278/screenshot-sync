import { common } from '@kit.AbilityKit';
import { dataSharePredicates } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { loadPairing, Pairing } from './Pairing';
import { ImageFormat, imageFormat } from './Protocol';
import { Receiver } from './Receiver';
import { assetReceipt, galleryAllowed, readImage, SyncCancellation, uploadImage } from './ScreenshotSync';

export class SelectedPhoto {
  constructor(
    public uri: string,
    public name: string,
    public thumbnail?: image.PixelMap,
    public receipt?: string
  ) {}
}

export class ManualResult {
  completed: string[] = [];
  error: string = '';
}

export async function selectPhotos(context: common.Context, pairing: Pairing): Promise<SelectedPhoto[]> {
  const options = new photoAccessHelper.PhotoSelectOptions();
  options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
  options.maxSelectNumber = 30;
  const picker = new photoAccessHelper.PhotoViewPicker();
  const selection: photoAccessHelper.PhotoSelectResult = await picker.select(options);
  const result: SelectedPhoto[] = [];
  if (selection.photoUris.length === 0) {
    return result;
  }
  const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  const canReadGallery: boolean = galleryAllowed(context);
  for (const uri of new Set(selection.photoUris)) {
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
    const selected = new SelectedPhoto(uri, uri.split('/').pop() ?? '');
    let assets: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> | undefined;
    try {
      assets = await helper.getAssets({
        fetchColumns: canReadGallery ? [photoAccessHelper.PhotoKeys.DATE_ADDED_MS] : [],
        predicates: predicates
      });
      if (assets.getCount() > 0) {
        const asset: photoAccessHelper.PhotoAsset = await assets.getFirstObject();
        selected.name = asset.displayName;
        if (canReadGallery) {
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
  context: common.Context, pairing: Pairing, selection: SelectedPhoto[], cancellation: SyncCancellation
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
      const format: ImageFormat | undefined = imageFormat(item.name) ?? identifyImage(bytes);
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
      const sent = await uploadImage(context, pairing, receiver, format, bytes, isCurrent);
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

function identifyImage(data: ArrayBuffer): ImageFormat | undefined {
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
