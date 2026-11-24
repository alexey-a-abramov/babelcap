import Foundation

public struct SonioxError: LocalizedError, Sendable, Equatable {
    public enum Action: Sendable { case fatalKey, fatalBalance, reconnect, backoff }
    public let code: Int
    public let message: String

    public init(code: Int, message: String) { self.code = code; self.message = message }

    public var action: Action {
        switch code {
        case 401: .fatalKey
        case 402: .fatalBalance
        case 408, 413: .reconnect
        default: .backoff // 429, 5xx, anything unknown
        }
    }

    public var isFatal: Bool { action == .fatalKey || action == .fatalBalance }

    public var errorDescription: String? {
        switch code {
        case 401: "Invalid Soniox API key"
        case 402: "Soniox balance is exhausted — top up at console.soniox.com"
        case 408: "Idle timeout"
        case 413: "Session limit reached"
        case 429: "Soniox rate limit (too many streams or requests)"
        case 0, 1000...: message   // local engines / warnings: the message says it all
        default: message.isEmpty ? "Soniox error \(code)" : "Soniox error \(code): \(message)"
        }
    }
}

public enum SonioxConnectionState: Sendable, Equatable {
    case connecting, live, reconnecting, closed, failed
}

public enum SonioxEvent: Sendable {
    case state(SonioxConnectionState)
    /// Tokens with `startMs/endMs` already shifted onto the session-wide audio timeline.
    case tokens([SonioxToken])
    case error(SonioxError)
    case finished
}
