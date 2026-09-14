import EmailAddress

// This narrow C entry point proves that the original implementation can be
// linked into a native shared library. The ArkTS bridge is a separate gate.
@_cdecl("thunderbird_email_address_probe")
public func thunderbirdEmailAddressProbe() -> Int32 {
  let address = EmailAddress(" \n Thunderbird 鸿蒙 <reader@example.com> \t")
  guard address.value == "reader@example.com" else { return 1 }
  guard address.label == "Thunderbird 鸿蒙" else { return 2 }
  guard address.host == "example.com", address.local == "reader" else { return 3 }
  guard address.isEmailAddress, "reader@example.com".isEmailAddress else { return 4 }
  guard !"invalid".isEmailAddress, !"@example.com".isEmailAddress else { return 5 }
  let first = EmailAddress.Group([address, EmailAddress("other@example.org")], label: "A")
  let second = EmailAddress.Group([EmailAddress("other@example.org"), address], label: "B")
  guard first == second else { return 6 }
  guard address.description == "Thunderbird 鸿蒙 <reader@example.com>" else { return 7 }
  return 0
}
