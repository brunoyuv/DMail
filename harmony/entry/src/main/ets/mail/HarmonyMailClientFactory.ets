import { JmapClientFactory, JmapCredentials, JmapService } from './jmap/JmapClient';
import { HarmonyJmapClientFactory } from './jmap/HarmonyJmapTransport';
import { NativeImapClient } from './imap/NativeImapClient';
export class HarmonyMailClientFactory implements JmapClientFactory {
  create(endpoint: string, credentials: JmapCredentials): JmapService {
    return endpoint.startsWith('imaps://') ? new NativeImapClient(endpoint, credentials, credentials.username ?? '') :
      new HarmonyJmapClientFactory().create(endpoint, credentials);
  }
}
