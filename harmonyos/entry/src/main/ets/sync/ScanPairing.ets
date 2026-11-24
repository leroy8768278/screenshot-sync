import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { PairingTarget, parsePairingQR } from './Protocol';

export async function scanPairing(context: common.UIAbilityContext): Promise<PairingTarget | undefined> {
  let result: scanBarcode.ScanResult;
  try {
    result = await scanBarcode.startScanForResult(context, {
      scanTypes: [scanCore.ScanType.QR_CODE], enableMultiMode: false, enableAlbum: false
    });
  } catch (error) {
    if ((error as BusinessError).code === scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
      return undefined;
    }
    throw new Error('无法打开系统扫一扫，请重试或手动输入配对信息');
  }
  const target = parsePairingQR(result.originalValue);
  if (!target) {
    throw new Error('请扫描 Mac 端即图显示的配对二维码');
  }
  return target;
}
