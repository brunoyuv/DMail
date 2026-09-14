// This Source Code Form is subject to the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import { util } from '@kit.ArkTS';
import { decodeMimeHeader, encodeMimeHeader, parseMimeBody } from '../../../main/ets/core/Mime';

interface Fixture { id: string; bytes: number; children?: number; firstType?: string; }
// Expected serialized lengths and part types from upstream MIMETests/BodyTests.swift.
const FIXTURES: Fixture[] = [
  { id: '2EA571DD', bytes: 4822, children: 1, firstType: 'text/html; charset="UTF-8"' },
  { id: '976C6A94', bytes: 30905 }, { id: '86925F24', bytes: 7800 },
  { id: '7A690F43', bytes: 1733 }, { id: '60EB5CAE', bytes: 6115 },
  { id: 'F02140B7', bytes: 89986, children: 2, firstType: 'text/html; charset="UTF-8"' },
  { id: 'BFA06D93', bytes: 69543, children: 2, firstType: 'text/plain; charset="UTF-8"' },
  { id: '89526045', bytes: 8795, children: 1, firstType: 'text/html; charset="ISO-8859-1"' },
  { id: 'E18BEE81', bytes: 21153 }, { id: '2874E3C9', bytes: 106182 },
  { id: '1759430F', bytes: 20589, children: 2, firstType: 'text/plain; charset="UTF-8"' },
  { id: 'E1FA0690', bytes: 148684 }, { id: 'CFD4D3A3', bytes: 591664 }
];

export default function mimeTests(): void {
  describe('ThunderbirdMIMENative', () => {
    it('upstream_header_vectors_and_concurrent_worker_calls', 0, async () => {
      const decoded = '❤️❤️❤️éÆ🤖"\\❤️❤️';
      const base64 = '=?UTF-8?B?4p2k77iP4p2k77iP4p2k77iPw6nDhvCfpJYiXOKdpO+4j+KdpO+4jw==?=';
      const quoted = '=?utf-8?Q?=E2=9D=A4=EF=B8=8F=E2=9D=A4=EF=B8=8F=E2=9D=A4=EF=B8=8F=C3=A9=C3=86=F0=9F=A4=96"\\=E2=9D=A4=EF=B8=8F=E2=9D=A4=EF=B8=8F?=';
      expect(await decodeMimeHeader(base64)).assertEqual(decoded);
      expect(await decodeMimeHeader(quoted)).assertEqual(decoded);
      expect(await encodeMimeHeader(decoded)).assertEqual(base64);
      expect(await encodeMimeHeader('Plain ASCII')).assertEqual('Plain ASCII');
      expect(await decodeMimeHeader('Plain ASCII')).assertEqual('Plain ASCII');
      expect(await encodeMimeHeader('')).assertEqual('');
      const tasks: Promise<string>[] = [];
      for (let index = 0; index < 20; index++) { tasks.push(decodeMimeHeader(index % 2 === 0 ? base64 : quoted)); }
      const results = await Promise.all(tasks);
      for (const result of results) { expect(result).assertEqual(decoded); }
    });

    it('all_thirteen_upstream_body_fixtures_parse_and_serialize', 0, async () => {
      const context = abilityDelegatorRegistry.getAbilityDelegator().getAppContext()
        .getApplicationContext().createModuleContext('entry_test');
      const base64 = new util.Base64Helper();
      const decoder = new util.TextDecoder('utf-8', { fatal: true });
      for (const fixture of FIXTURES) {
        const data = await context.resourceManager.getRawFileContent(`mime/mime-body-${fixture.id}.eml`);
        const body = await parseMimeBody(decoder.decodeToString(data));
        expect(body.isEmpty).assertFalse();
        const serialized = base64.decodeSync(body.rawValueBase64);
        expect(serialized.length).assertEqual(fixture.bytes);
        if (fixture.children !== undefined) {
          expect(body.part.parts.length).assertEqual(fixture.children);
          expect(body.part.parts[0].contentType).assertEqual(fixture.firstType);
        }
        const restored = await parseMimeBody(decoder.decodeToString(serialized));
        expect(restored.rawValueBase64).assertEqual(body.rawValueBase64);
        expect(restored.part.contentType).assertEqual(body.part.contentType);
      }
    });

    it('malformed_mime_rejects_without_breaking_later_requests', 0, async () => {
      let invalidHeader = false;
      try { await decodeMimeHeader('=?utf-8?Q?=ZZ?='); } catch (_) { invalidHeader = true; }
      expect(invalidHeader).assertTrue();
      const invalidBodies: string[] = ['no MIME headers', 'Content-Type: text/plain\r\n\r\n鸿蒙',
        'Content-Type: text/plain\r\n\r\nvalid\u0000ignored'];
      for (const input of invalidBodies) {
        let rejected = false;
        try { await parseMimeBody(input); } catch (_) { rejected = true; }
        expect(rejected).assertTrue();
      }
      const body = await parseMimeBody('Content-Type: text/plain; charset="US-ASCII"\r\n\r\nHello');
      expect(body.part.parts.length).assertEqual(0);
      expect(body.part.contentType).assertEqual('text/plain; charset="US-ASCII"');
      expect(body.part.encodedPayloadBase64).assertEqual('SGVsbG8=');
    });
  });
}
