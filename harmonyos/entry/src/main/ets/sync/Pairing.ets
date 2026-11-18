import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { isLocalAddress, isPairingCode } from './Protocol';

export class Pairing {
  constructor(
    public host: string,
    public token: string,
    public sinceMs: number,
    public installation: string,
    public destination: string,
    public enabled: boolean
  ) {}
}

function pathFor(context: common.Context): string {
  return context.getApplicationContext().filesDir + '/screenshot-sync.json';
}

export function loadPairing(context: common.Context): Pairing | undefined {
  const path: string = pathFor(context);
  if (!fileIo.accessSync(path)) {
    return undefined;
  }
  const value: Pairing = JSON.parse(fileIo.readTextSync(path)) as Pairing;
  if (typeof value.host !== 'string' || !isLocalAddress(value.host) ||
    typeof value.token !== 'string' || !isPairingCode(value.token) ||
    typeof value.installation !== 'string' || !/^[a-f0-9]{32}$/.test(value.installation) ||
    typeof value.destination !== 'string' || !/^[a-f0-9]{32}$/.test(value.destination) ||
    !Number.isSafeInteger(value.sinceMs) || value.sinceMs < 0 || typeof value.enabled !== 'boolean') {
    throw new Error('本机配对设置无法读取');
  }
  return value;
}

function randomID(): string {
  return util.generateRandomUUID(true).replace(/-/g, '').toLowerCase();
}

export function createPairing(
  host: string, token: string, includeExisting: boolean, previous?: Pairing
): Pairing {
  const sameDestination: boolean = previous !== undefined && previous.token === token;
  return new Pairing(host, token,
    sameDestination && previous ? previous.sinceMs : includeExisting ? 0 : Date.now(),
    previous ? previous.installation : randomID(),
    sameDestination && previous ? previous.destination : randomID(),
    true);
}

export function savePairing(context: common.Context, value: Pairing): void {
  const path: string = pathFor(context);
  const temporaryPath: string = path + '.tmp';
  const file: fileIo.File = fileIo.openSync(temporaryPath,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
  try {
    const data: string = JSON.stringify(value);
    if (fileIo.writeSync(file.fd, data) !== data.length) {
      throw new Error('保存配对设置失败');
    }
    fileIo.fsyncSync(file.fd);
  } finally {
    fileIo.closeSync(file);
  }
  fileIo.renameSync(temporaryPath, path);
}
