// MPL-2.0: https://mozilla.org/MPL/2.0/
import { url } from '@kit.ArkTS';
import { JmapClient, JmapClientFactory, JmapCredentials, JmapService, JmapTransport, ParsedEndpoint, JmapError } from './JmapClient';
import { NativeJmapAccountCore } from './NativeJmapAccountCore';

export class HarmonyJmapTransport implements JmapTransport {
  readonly accountCore: NativeJmapAccountCore = new NativeJmapAccountCore();
  parseUrl(value: string, base?: string): ParsedEndpoint {
    try {
      const parsed = url.URL.parseURL(value, base);
      return { href: parsed.href, origin: parsed.origin, protocol: parsed.protocol,
        username: parsed.username, password: parsed.password, hash: parsed.hash };
    } catch (_) { throw new JmapError('unsafeEndpoint'); }
  }
}

export class HarmonyJmapClientFactory implements JmapClientFactory {
  create(sessionUrl: string, credentials: JmapCredentials): JmapService {
    return new JmapClient(sessionUrl, new HarmonyJmapTransport(), credentials);
  }
}
