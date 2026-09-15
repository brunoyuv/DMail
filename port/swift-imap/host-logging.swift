// MPL-2.0: https://mozilla.org/MPL/2.0/
// Host-test-only OSLog stand-in; not a HarmonyOS runtime adapter.
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func info(_ message: Message) {}
    public func debug(_ message: Message) {}
    public func error(_ message: Message) {}
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        public init(stringLiteral: String) {}
        public init(stringInterpolation: StringInterpolation) {}
        public struct StringInterpolation: StringInterpolationProtocol {
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) {}
            public mutating func appendInterpolation<T>(_ value: T) {}
        }
    }
}
