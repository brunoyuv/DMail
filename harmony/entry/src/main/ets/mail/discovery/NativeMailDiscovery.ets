// MPL-2.0: https://mozilla.org/MPL/2.0/
import { discoveryRequest } from 'libthunderbird.so';

export interface DiscoveredServer {
  protocolName: string;
  hostname: string;
  port: number;
  security: string;
  username: string;
  authentication: string[];
  supported: boolean;
  reason: string;
}
export interface MailConfiguration {
  name: string;
  source: string;
  incoming: DiscoveredServer[];
  outgoing: DiscoveredServer[];
}
export interface MailDiscoveryService {
  discover(email: string): Promise<MailConfiguration>;
}
interface DiscoveryInput { operation: string; email: string; }
interface DiscoveryReply { configuration?: MailConfiguration; error?: string; }
export class DiscoveryError extends Error {
  code: string;
  constructor(code: string) { super(code); this.code = code; }
}
export class NativeMailDiscovery implements MailDiscoveryService {
  async discover(email: string): Promise<MailConfiguration> {
    const request: DiscoveryInput = { operation: 'discover', email: email.trim() };
    const reply = JSON.parse(await discoveryRequest(JSON.stringify(request))) as DiscoveryReply;
    if (reply.error || !reply.configuration) { throw new DiscoveryError(reply.error ?? 'invalidConfiguration'); }
    return reply.configuration;
  }
}
