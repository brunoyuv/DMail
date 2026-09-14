import Musl
import RegexBuilder
import Synchronization
import FoundationEssentials

private struct Envelope: Codable, Equatable {
  let subject: String
  let unread: Bool
}

@_cdecl("swift_harmony_runtime_probe")
public func swiftHarmonyPlatformProbe() -> Int32 {
  guard !CommandLine.arguments.isEmpty else { return 20 }
  do {
    let original = Envelope(subject: "Thunderbird 鸿蒙", unread: true)
    let encoded = try JSONEncoder().encode(original)
    guard try JSONDecoder().decode(Envelope.self, from: encoded) == original else { return 28 }
    guard URL(string: "https://example.com/inbox")?.host() == "example.com" else { return 29 }
    let names = try FileManager.default.contentsOfDirectory(atPath: "/data/local/tmp/thunderbird-swift-ohos")
    guard names.contains("platform-probe") else { return 30 }
  } catch { return 31 }
  do {
    let regex = try Regex("Thunderbird\\s+鸿蒙")
    guard try "Thunderbird 鸿蒙".wholeMatch(of: regex) != nil else { return 21 }
    guard try "Thunderbird".wholeMatch(of: regex) == nil else { return 22 }
  } catch { return 23 }
  let value = Mutex(3)
  value.withLock { $0 += 4 }
  guard value.withLock({ $0 }) == 7 else { return 24 }
  guard let path = strdup("/data/local/tmp/thunderbird-swift-ohos") else { return 25 }
  defer { free(path) }
  var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
  return paths.withUnsafeMutableBufferPointer { buffer in
    guard let tree = fts_open(buffer.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 26 }
    var files = 0
    var directories = 0
    var failed = false
    while let entry = fts_read(tree) {
      switch Int32(entry.pointee.fts_info) {
      case FTS_F: files += 1
      case FTS_D: directories += 1
      case FTS_ERR, FTS_DNR, FTS_NS: failed = true
      default: break
      }
    }
    let closed = fts_close(tree)
    guard !failed, closed == 0, files > 0, directories > 0 else { return 27 }
    return 0
  }
}
