// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import { describe, it, expect } from '@ohos/hypium';
import { validateEmailAddress } from 'libthunderbird.so';

export default function nativeCoreTests(): void {
  describe('ThunderbirdSwiftNative', () => {
    it('original_email_address_validation_through_node_api', 0, () => {
      expect(validateEmailAddress('reader@example.com')).assertTrue();
      expect(validateEmailAddress('  鸿蒙 📬 <reader@example.com>  ')).assertTrue();
      expect(validateEmailAddress('reader+tag@example.com')).assertTrue();
      expect(validateEmailAddress('')).assertFalse();
      expect(validateEmailAddress('reader')).assertFalse();
      expect(validateEmailAddress('@example.com')).assertFalse();
      expect(validateEmailAddress('reader@')).assertFalse();
      expect(validateEmailAddress('reader@example.com\u0000ignored')).assertFalse();
    });

  });
}
