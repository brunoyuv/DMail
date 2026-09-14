// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import EmailAddress
import MIME
import Foundation

// A compatibility probe, not a replacement implementation or production UI.
let address = EmailAddress("Thunderbird 鸿蒙 <reader@example.com>")
precondition(address.value == "reader@example.com")
precondition(address.label == "Thunderbird 鸿蒙")
precondition(address.host == "example.com")
precondition(address.local == "reader")
precondition(address.isEmailAddress)
print("UPSTREAM_EMAIL_ADDRESS_OK")
print(address.description)

let original = Part(data: Data("Thunderbird MIME probe".utf8), contentTransferEncoding: .ascii,
                    contentType: .text(.plain, .ascii))
let decoded = try Part(original.rawValue)
precondition(decoded.data == original.data)
precondition(decoded.contentType == original.contentType)
precondition(decoded.contentTransferEncoding == .ascii)
print("UPSTREAM_MIME_ROUNDTRIP_OK")
