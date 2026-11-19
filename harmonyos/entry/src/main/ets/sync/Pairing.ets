import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { isLocalAddress, isPairingCode } from './Protocol';

export class Pairing {
  constructor(
    public host: string,
    public token: string,
    public pairedAfterMs: number | undefined,
    public installation: string,
    public destination: string,
    public enabled: boolean,
    public revision: number
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
  value.revision = value.revision ?? 0;
  if (typeof value.host !== 'string' || !isLocalAddress(value.host) ||
    typeof value.token !== 'string' || !isPairingCode(value.token) ||
    typeof value.installation !== 'string' || !/^[a-f0-9]{32}$/.test(value.installation) ||
    typeof value.destination !== 'string' || !/^[a-f0-9]{32}$/.test(value.destination) ||
    (value.pairedAfterMs !== undefined &&
      (!Number.isSafeInteger(value.pairedAfterMs) || value.pairedAfterMs <= 0)) ||
    typeof value.enabled !== 'boolean' ||
    !Number.isSafeInteger(value.revision) || value.revision < 0) {
    throw new Error('本机配对设置无法读取');
  }
  return value;
}

function randomID(): string {
  return util.generateRandomUUID(true).replace(/-/g, '').toLowerCase();
}

export function createPairing(
  context: common.Context, host: string, token: string, verifiedAt: number, previous?: Pairing
): Pairing {
  const sameDestination: boolean = previous !== undefined && previous.token === token;
  const installationPath: string = pathFor(context) + '.installation';
  const knownInstallation: string | undefined = previous?.installation ??
    (fileIo.accessSync(installationPath) ? fileIo.readTextSync(installationPath) : undefined);
  const installation: string = knownInstallation && /^[a-f0-9]{32}$/.test(knownInstallation) ?
    knownInstallation : randomID();
  // Older versions stored the most recent app launch time. Only carry forward an authenticated cutoff.
  return new Pairing(host, token, (sameDestination ? previous?.pairedAfterMs : undefined) ?? verifiedAt, installation,
    sameDestination && previous ? previous.destination : randomID(),
    previous?.enabled ?? true, (previous?.revision ?? verifiedAt) + 1);
}

export function withSyncEnabled(pairing: Pairing, enabled: boolean): Pairing {
  return new Pairing(pairing.host, pairing.token, pairing.pairedAfterMs, pairing.installation, pairing.destination,
    enabled, pairing.revision + 1);
}

export function clearPairing(context: common.Context): void {
  const pairing: Pairing | undefined = loadPairing(context);
  if (pairing) {
    const path: string = pathFor(context);
    replaceFile(path + '.installation', pairing.installation);
    fileIo.unlinkSync(path);
  }
}

export function savePairing(context: common.Context, value: Pairing): void {
  replaceFile(pathFor(context), JSON.stringify(value));
}

function replaceFile(path: string, data: string): void {
  const temporaryPath: string = path + '.tmp';
  const file: fileIo.File = fileIo.openSync(temporaryPath,
    fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
  try {
    if (fileIo.writeSync(file.fd, data) !== data.length) {
      throw new Error('保存配对设置失败');
    }
    fileIo.fsyncSync(file.fd);
  } finally {
    fileIo.closeSync(file);
  }
  fileIo.renameSync(temporaryPath, path);
}
