// MPL-2.0: https://mozilla.org/MPL/2.0/
import CHarmonyLogging

/// The subset of OSLog used by the upstream JMAP and IMAP clients, backed by HiLog.
/// Interpolated values remain private, including mailbox names.
public struct Logger: Sendable {
    private let category: String
    public init(subsystem: String, category: String) {
        self.category = subsystem + "/" + category
    }
    public func info(_ message: Message) {
        category.withCString { category in
            message.text.withCString { thunderbird_hilog_info(category, $0) }
        }
    }
    public func debug(_ message: Message) {
        category.withCString { category in
            message.text.withCString { thunderbird_hilog_debug(category, $0) }
        }
    }
    public func error(_ message: Message) {
        category.withCString { category in
            message.text.withCString { thunderbird_hilog_error(category, $0) }
        }
    }
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        fileprivate let text: String
        public init(stringLiteral value: String) { text = value }
        public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
        public struct StringInterpolation: StringInterpolationProtocol {
            fileprivate var text = ""
            public init(literalCapacity: Int, interpolationCount: Int) {
                text.reserveCapacity(literalCapacity + interpolationCount * 9)
            }
            public mutating func appendLiteral(_ literal: String) { text += literal }
            public mutating func appendInterpolation<T>(_ value: T) { text += "<private>" }
        }
    }
}
