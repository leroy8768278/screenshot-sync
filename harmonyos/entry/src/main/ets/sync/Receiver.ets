import { buffer } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { ChatMessage, ChatPage, MAX_CHAT_FILE, MAX_CHAT_TEXT } from './ChatTypes';
import { MediaFormat, RECEIVER_PORT } from './Protocol';

interface HealthResponse {
  status: string;
}

interface DeviceInfo {
  model?: string;
  osVersion?: string;
}

function availableInfo(read: () => string, limit: number): string | undefined {
  try {
    const text: string = read().trim();
    if (text.length > 0 && text.toLowerCase() !== 'unknown' &&
      buffer.from(text, 'utf-8').length <= limit &&
      !/(?![\u200C\u200D])[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(text)) {
      return text;
    }
  } catch (_error) {
    // Individual device properties can be unavailable.
  }
  return undefined;
}

export async function findVerifiedHost(hosts: string[], token: string): Promise<string> {
  let message = '无法连接到 Mac，请确认手机和 Mac 在同一局域网';
  for (const host of hosts) {
    const receiver = new Receiver(host, token);
    try {
      await receiver.verify();
      return host;
    } catch (error) {
      if (error instanceof Error) {
        message = error.message;
      }
    } finally {
      receiver.close();
    }
  }
  throw new Error(message);
}

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
    request.configuration = {
      proxy: 'no-proxy',
      transfer: { autoRedirect: false, timeout: { connectMs: 1500, transferMs: 2500 } }
    };
    const response: rcp.Response = await this.fetch(request);
    if (response.statusCode !== 200) {
      this.failStatus(response.statusCode);
    }
    const health = response.toJSON() as HealthResponse | null;
    if (health?.status !== 'ok') {
      throw new Error('此地址未返回即图接收端的配对响应');
    }
  }

  static async reportDevice(host: string, token: string, deviceId: string): Promise<void> {
    let receiver: Receiver | undefined;
    try {
      receiver = new Receiver(host, token);
      const headers = receiver.deviceHeaders(deviceId);
      headers['Content-Length'] = '0';
      await receiver.fetch(new rcp.Request(receiver.baseURL + '/v1/devices', 'POST', headers));
    } catch (_error) {
      // The verified pairing remains usable when the optional announcement fails.
    } finally {
      receiver?.close();
    }
  }

  private deviceHeaders(deviceId: string): Record<string, string> {
    const headers: Record<string, string> = {
      'Authorization': this.authorization,
      'X-Device-ID': deviceId,
      'X-Device-Platform': 'harmony'
    };
    try {
      const info: DeviceInfo = {
        model: availableInfo((): string => deviceInfo.marketName, 256) ??
          availableInfo((): string => deviceInfo.productModel, 256),
        osVersion: availableInfo((): string => deviceInfo.distributionOSVersion, 128)
      };
      headers['X-Device-Info'] = buffer.from(JSON.stringify(info), 'utf-8').toString('base64');
    } catch (_error) {
      // A device without readable system metadata can still upload.
    }
    return headers;
  }

  async upload(id: string, deviceId: string, filename: string, format: MediaFormat, image: ArrayBuffer): Promise<boolean> {
    return this.sendUpload(id, deviceId, filename, format, image, image.byteLength);
  }

  async uploadVideo(
    id: string, deviceId: string, filename: string, format: MediaFormat, fd: number, length: number
  ): Promise<boolean> {
    return this.sendUpload(id, deviceId, filename, format, new rcp.UploadFromFile(fd), length);
  }

  private async sendUpload(
    id: string, deviceId: string, filename: string, format: MediaFormat, content: rcp.RequestContent, length: number
  ): Promise<boolean> {
    const headers = this.deviceHeaders(deviceId);
    headers['X-Screenshot-ID'] = id;
    headers['X-Filename'] = filename;
    headers['Content-Type'] = format.mimeType;
    headers['Content-Length'] = String(length);
    const request = new rcp.Request(this.baseURL + '/v1/screenshots', 'POST', headers, content);
    if (format.mimeType.startsWith('video/')) {
      request.configuration = {
        proxy: 'no-proxy',
        transfer: {
          autoRedirect: false,
          timeout: { connectMs: 4000, transferMs: 900000 }
        }
      };
    }
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

  private chatHeaders(device: string, key: string): Record<string, string> {
    const headers: Record<string, string> = this.deviceHeaders(device);
    headers['X-Chat-Key'] = key;
    return headers;
  }

  async chatPage(device: string, key: string, after: number): Promise<ChatPage> {
    const request = new rcp.Request(this.baseURL + '/v1/chat/messages?after=' + after, 'GET',
      this.chatHeaders(device, key));
    const response = await this.fetch(request);
    if (response.statusCode !== 200) {
      this.failStatus(response.statusCode);
    }
    const page = response.toJSON() as ChatPage | null;
    if (!page || !Array.isArray(page.messages) || typeof page.hasMore !== 'boolean' || typeof page.macName !== 'string') {
      throw new Error('无法读取对话记录');
    }
    let previous: number = after;
    for (const message of page.messages) {
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(message.id) ||
        !Number.isSafeInteger(message.sequence) || message.sequence <= previous || !Number.isFinite(message.createdAt) ||
        (message.sender !== 'mac' && message.sender !== 'phone') ||
        (message.kind !== 'text' && message.kind !== 'file') ||
        !Number.isSafeInteger(message.bytes) || message.bytes < 0 ||
        (message.kind === 'file' && (message.bytes > MAX_CHAT_FILE || typeof message.filename !== 'string' ||
          !message.filename || message.filename === '.' || message.filename === '..' ||
          /[\/\\:\u0000-\u001F\u007F]/.test(message.filename))) ||
        (message.kind === 'text' && (message.bytes > MAX_CHAT_TEXT || typeof message.text !== 'string'))) {
        throw new Error('对话记录格式无效');
      }
      previous = message.sequence;
    }
    if (page.hasMore && page.messages.length === 0) {
      throw new Error('对话记录分页无效');
    }
    return page;
  }

  async sendChat(device: string, key: string, id: string, content: rcp.RequestContent,
    bytes: number, filename?: string): Promise<void> {
    const headers = this.chatHeaders(device, key);
    headers['X-Message-ID'] = id;
    headers['Content-Length'] = String(bytes);
    headers['Content-Type'] = filename === undefined ? 'text/plain; charset=utf-8' : 'application/octet-stream';
    if (filename !== undefined) {
      headers['X-File-Name'] = buffer.from(filename, 'utf-8').toString('base64');
    }
    const route = filename === undefined ? '/v1/chat/text' : '/v1/chat/file';
    const request = new rcp.Request(this.baseURL + route, 'POST', headers, content);
    request.configuration = {
      proxy: 'no-proxy', transfer: { autoRedirect: false, timeout: { connectMs: 4000, transferMs: 600000 } }
    };
    const response = await this.fetch(request);
    if (response.statusCode !== 200 && response.statusCode !== 201) {
      this.failStatus(response.statusCode);
    }
    const saved = response.toJSON() as ChatMessage | null;
    if (!saved || typeof saved.id !== 'string' || saved.id.toLowerCase() !== id.toLowerCase()) {
      throw new Error('未收到发送确认，请重试');
    }
  }

  async downloadChat(device: string, key: string, id: string, path: string): Promise<void> {
    const destination: rcp.DownloadToFile = { kind: 'file', file: path };
    const request = new rcp.Request(this.baseURL + '/v1/chat/files/' + id, 'GET', this.chatHeaders(device, key));
    request.destination = destination;
    request.configuration = {
      proxy: 'no-proxy', transfer: { autoRedirect: false, timeout: { connectMs: 4000, transferMs: 600000 } }
    };
    const response = await this.fetch(request);
    if (response.statusCode !== 200) {
      this.failStatus(response.statusCode);
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
