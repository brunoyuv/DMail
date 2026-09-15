import EmailAddress

// C ABI for the ArkTS Node-API adapter. Validation stays in Thunderbird's
// original EmailAddress implementation; this layer only handles UTF-8 input.
@_cdecl("thunderbird_email_address_validate")
public func thunderbirdEmailAddressValidate(_ input: UnsafePointer<CChar>?) -> Int32 {
  guard let input, let value = String(validatingCString: input) else { return 0 }
  return EmailAddress(value).isEmailAddress ? 1 : 0
}
