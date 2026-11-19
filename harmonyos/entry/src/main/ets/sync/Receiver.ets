import { connection } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ImageFormat, RECEIVER_PORT } from './Protocol';

export class Receiver {
  private session: rcp.Session;
  private baseURL: string;
  private authorization: string;
  private closed: boolean = false;

  constructor(host: string, token: string) {
    this.baseURL = `http://${host}:${RECEIVER_PORT}`;
    this.authorization = 'Bearer ' + token;
    this.session = rcp.createSession({
      requestConfiguration: {
        proxy: 'no-proxy',
        transfer: {
          autoRedirect: false,
          timeout: { connectMs: 4000, transferMs: 12000 }
        }
      }
    });
  }

  async verify(): Promise<void> {
    const request = new rcp.Request(this.baseURL + '/v1/health', 'GET', {
      'Authorization': this.authorization
    });
    const response: rcp.Response = await this.fetch(request);
    if (response.statusCode !== 200) {
      this.failStatus(response.statusCode);
    }
  }

  async upload(id: string, deviceId: string, filename: string, format: ImageFormat, image: ArrayBuffer): Promise<boolean> {
    const request = new rcp.Request(this.baseURL + '/v1/screenshots', 'POST', {
      'Authorization': this.authorization,
      'X-Screenshot-ID': id,
      'X-Device-ID': deviceId,
      'X-Filename': filename,
      'Content-Type': format.mimeType,
      'Content-Length': String(image.byteLength)
    }, image);
    const response: rcp.Response = await this.fetch(request);
    switch (response.statusCode) {
      case 200:
      case 201:
        return true;
      case 413:
      case 415:
      case 422:
        return false;
      default:
        return this.failStatus(response.statusCode);
    }
  }

  cancel(): void {
    if (this.closed) {
      return;
    }
    try {
      this.session.cancel();
    } catch (_error) {
      // The native session may already have stopped.
    }
    this.close();
  }

  close(): void {
    if (!this.closed) {
      this.closed = true;
      try {
        this.session.close();
      } catch (_error) {
        // The native session may already have closed.
      }
    }
  }

  private async fetch(request: rcp.Request): Promise<rcp.Response> {
    await requireLocalNetwork();
    if (this.closed) {
      throw new Error('同步已停止');
    }
    try {
      return await this.session.fetch(request);
    } catch (_error) {
      throw new Error('暂时无法连接到 Mac，请确认接收端正在运行且位于同一局域网');
    }
  }

  private failStatus(status: number): never {
    if (status === 401 || status === 403) {
      throw new Error('Mac 拒绝了配对码，请核对后重试');
    }
    throw new Error(`Mac 返回 HTTP ${status}`);
  }
}

async function requireLocalNetwork(): Promise<void> {
  try {
    const handle: connection.NetHandle = await connection.getDefaultNet();
    if (handle.netId !== 0) {
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(handle);
      if (caps.bearerTypes.includes(connection.NetBearType.BEARER_WIFI) ||
        caps.bearerTypes.includes(connection.NetBearType.BEARER_ETHERNET)) {
        return;
      }
    }
  } catch (_error) {
    // Network state can change while the capabilities are being queried.
  }
  throw new Error('等待连接 Wi-Fi 或有线局域网');
}
