export const RECEIVER_PORT: number = 43871;
export const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;
export const MAX_VIDEO_BYTES: number = 512 * 1024 * 1024;

export function parseReceiverHost(address: string): string | undefined {
  const input: string = address.trim();
  const portSuffix: string = `:${RECEIVER_PORT}`;
  const host: string = input.endsWith(portSuffix) ? input.slice(0, -portSuffix.length) : input;
  return isLocalAddress(host) ? host : undefined;
}

export function isLocalAddress(host: string): boolean {
  if (!/^(0|[1-9]\d{0,2})(\.(0|[1-9]\d{0,2})){3}$/.test(host)) {
    return false;
  }
  const parts: number[] = host.split('.').map((part: string): number => Number(part));
  if (parts.some((part: number): boolean => part > 255)) {
    return false;
  }
  const first: number = parts[0];
  const second: number = parts[1];
  return first === 10 || (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168) || (first === 169 && second === 254) ||
    host === '127.0.0.1';
}

export function isPairingCode(token: string): boolean {
  return token.length === 24 && /^[0-9a-f]{24}$/.test(token);
}

interface PairingPayload {
  type: string;
  version: number;
  addresses: string[];
  token: string;
}

export class PairingTarget {
  constructor(public hosts: string[], public token: string) {}
}

export function parsePairingQR(text: string): PairingTarget | undefined {
  if (text.length > 4096) {
    return undefined;
  }
  let value: PairingPayload;
  try {
    value = JSON.parse(text) as PairingPayload;
  } catch (_error) {
    return undefined;
  }
  if (!value || value.type !== 'snaprelay-pair' || value.version !== 1 ||
    typeof value.token !== 'string' || !isPairingCode(value.token.toLowerCase()) ||
    !Array.isArray(value.addresses) || value.addresses.length < 1 || value.addresses.length > 16) {
    return undefined;
  }
  const hosts: string[] = [];
  for (const address of value.addresses) {
    if (typeof address !== 'string') {
      return undefined;
    }
    const match = address.match(/^http:\/\/([0-9.]+):([0-9]+)\/?$/);
    if (!match || match[0] !== address || match[2] !== String(RECEIVER_PORT) ||
      !isLocalAddress(match[1]) || match[1] === '127.0.0.1') {
      return undefined;
    }
    if (!hosts.includes(match[1])) {
      hosts.push(match[1]);
    }
  }
  return new PairingTarget(hosts, value.token.toLowerCase());
}

export class MediaFormat {
  constructor(public extension: string, public mimeType: string) {}
}

export function imageFormat(displayName: string): MediaFormat | undefined {
  const name: string = displayName.toLowerCase();
  if (name.endsWith('.png')) {
    return new MediaFormat('png', 'image/png');
  }
  if (name.endsWith('.jpeg') || name.endsWith('.jpg')) {
    return new MediaFormat('jpg', 'image/jpeg');
  }
  if (name.endsWith('.heic')) {
    return new MediaFormat('heic', 'image/heic');
  }
  if (name.endsWith('.heif')) {
    return new MediaFormat('heif', 'image/heif');
  }
  if (name.endsWith('.webp')) {
    return new MediaFormat('webp', 'image/webp');
  }
  if (name.endsWith('.gif')) {
    return new MediaFormat('gif', 'image/gif');
  }
  if (name.endsWith('.tiff') || name.endsWith('.tif')) {
    return new MediaFormat('tiff', 'image/tiff');
  }
  if (name.endsWith('.bmp')) {
    return new MediaFormat('bmp', 'image/bmp');
  }
  return undefined;
}

export function videoFormat(displayName: string): MediaFormat | undefined {
  const name: string = displayName.toLowerCase();
  if (name.endsWith('.mp4')) {
    return new MediaFormat('mp4', 'video/mp4');
  }
  if (name.endsWith('.mov')) {
    return new MediaFormat('mov', 'video/quicktime');
  }
  if (name.endsWith('.m4v')) {
    return new MediaFormat('m4v', 'video/x-m4v');
  }
  return undefined;
}
