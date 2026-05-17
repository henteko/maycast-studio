import Foundation

public enum LogLevel: String, Sendable {
    case debug, info, warn, error
}

public protocol LoggerProtocol: Sendable {
    func log(_ level: LogLevel, _ message: @autoclosure () -> String)
}

public struct StdErrLogger: LoggerProtocol {
    public let label: String
    public let minimumLevel: LogLevel

    public init(label: String, minimumLevel: LogLevel = .info) {
        self.label = label
        self.minimumLevel = minimumLevel
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> String) {
        guard shouldLog(level) else { return }
        let line = "[\(level.rawValue)] \(label): \(message())\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func shouldLog(_ level: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warn, .error]
        guard let current = order.firstIndex(of: level),
              let threshold = order.firstIndex(of: minimumLevel)
        else { return true }
        return current >= threshold
    }
}
