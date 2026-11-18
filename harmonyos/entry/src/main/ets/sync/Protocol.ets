export const RECEIVER_PORT: number = 43871;
export const MAX_IMAGE_BYTES: number = 64 * 1024 * 1024;

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
  return /^[0-9a-f]{24}$/.test(token);
}

export class ImageFormat {
  constructor(public extension: string, public mimeType: string) {}
}

export function imageFormat(displayName: string): ImageFormat | undefined {
  const name: string = displayName.toLowerCase();
  if (name.endsWith('.png')) {
    return new ImageFormat('png', 'image/png');
  }
  if (name.endsWith('.jpeg') || name.endsWith('.jpg')) {
    return new ImageFormat('jpg', 'image/jpeg');
  }
  if (name.endsWith('.heic')) {
    return new ImageFormat('heic', 'image/heic');
  }
  if (name.endsWith('.heif')) {
    return new ImageFormat('heif', 'image/heif');
  }
  if (name.endsWith('.webp')) {
    return new ImageFormat('webp', 'image/webp');
  }
  return undefined;
}
