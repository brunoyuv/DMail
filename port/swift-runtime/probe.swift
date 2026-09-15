// A runtime ABI smoke test, not Thunderbird source or Foundation coverage.
@_cdecl("swift_harmony_runtime_probe")
public func swiftHarmonyRuntimeProbe() -> Int32 {
  let label = "Thunderbird 鸿蒙"
  guard String(decoding: Array(label.utf8), as: UTF8.self) == label else { return 1 }
  guard label.count == 14, label.hasSuffix("鸿蒙") else { return 2 }
  guard [9, -2, 4].sorted() == [-2, 4, 9] else { return 3 }
  var lookup = ["reader": 1]
  lookup["reader", default: 0] += 2
  guard lookup["reader"] == 3 else { return 4 }
  guard Double("-12.5") == -12.5, String(1.25) == "1.25" else { return 5 }
  return 0
}
