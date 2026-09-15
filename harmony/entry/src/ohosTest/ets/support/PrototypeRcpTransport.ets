// Historical Remote Communication Kit tests only.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { rcp } from '@kit.RemoteCommunicationKit';
import { url, util } from '@kit.ArkTS';
import { JmapTransport, JmapHttpRequest, JmapHttpResponse, ParsedEndpoint, JmapError } from './PrototypeJmapClient';

export class PrototypeRcpTransport implements JmapTransport {
  parseUrl(value: string, base?: string): ParsedEndpoint {
    try {
      const parsed = url.URL.parseURL(value, base);
      return { href: parsed.href, origin: parsed.origin, protocol: parsed.protocol,
        username: parsed.username, password: parsed.password, hash: parsed.hash };
    } catch (_) { throw new JmapError('unsafeEndpoint'); }
  }

  private createSession(): rcp.Session {
    try {
      return rcp.createSession({
        requestConfiguration: { transfer: { autoRedirect: false,
          timeout: { connectMs: 10000, transferMs: 30000 } } },
        cacheControl: { noStore: true }
      });
    } catch (_) { throw new JmapError('network'); }
  }

  async send(input: JmapHttpRequest): Promise<JmapHttpResponse> {
    const session = this.createSession();
    const request = new rcp.Request(input.url, input.method, input.headers, input.body);
    const chunks: Uint8Array[] = [];
    let size = 0;
    let tooLarge = false;
    request.destination = (data: ArrayBuffer): void => {
      size += data.byteLength;
      if (size > input.maxResponseBytes) {
        tooLarge = true;
        session.cancel(request);
        return;
      }
      chunks.push(new Uint8Array(data).slice());
    };
    try {
      const response = await session.fetch(request);
      if (tooLarge) { throw new JmapError('responseTooLarge'); }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const headers: Record<string, string> = {};
      for (const key of Object.keys(response.headers)) {
        const value = response.headers[key];
        if (typeof value === 'string') { headers[key] = value; }
        else if (Array.isArray(value)) { headers[key] = value.join(','); }
      }
      return { status: response.statusCode, headers,
        body: new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes) };
    } catch (_) {
      throw new JmapError(tooLarge ? 'responseTooLarge' : 'network');
    } finally {
      session.close();
    }
  }
}
