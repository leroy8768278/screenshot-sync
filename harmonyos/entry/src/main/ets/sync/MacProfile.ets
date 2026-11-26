export class MacProfile {
  constructor(public name: string = '', public family: string = 'mac') {}
}

export function familyName(family: string): string {
  switch (family) {
    case 'mac-mini': return 'Mac mini';
    case 'mac-studio': return 'Mac Studio';
    case 'imac': return 'iMac';
    case 'mac-pro': return 'Mac Pro';
    case 'macbook-air': return 'MacBook Air';
    case 'macbook-pro': return 'MacBook Pro';
    case 'macbook': return 'MacBook';
    case 'macbook-neo': return 'MacBook Neo';
    default: return 'Mac';
  }
}

export function macProfile(rawName?: string, rawFamily?: string): MacProfile {
  const name: string = typeof rawName === 'string' ? rawName.trim() : '';
  const family: string = typeof rawFamily === 'string' && familyName(rawFamily) !== 'Mac' ? rawFamily : 'mac';
  return new MacProfile(name.length <= 256 && !/(?![\u200C\u200D])[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(name) ? name : '', family);
}

export function macDisplayName(mac: MacProfile): string {
  return mac.name || familyName(mac.family);
}

export function macArtwork(family: string): Resource {
  switch (family) {
    case 'mac-mini': return $r('app.media.receiver_mac_mini');
    case 'mac-studio': return $r('app.media.receiver_mac_studio');
    case 'imac': return $r('app.media.receiver_imac');
    case 'mac-pro': return $r('app.media.receiver_mac_pro');
    case 'macbook-air': return $r('app.media.receiver_macbook_air');
    case 'macbook-pro': return $r('app.media.receiver_macbook_pro');
    case 'macbook': return $r('app.media.receiver_macbook');
    case 'macbook-neo': return $r('app.media.receiver_macbook_neo');
    default: return $r('app.media.receiver_mac');
  }
}
