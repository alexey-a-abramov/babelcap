import Foundation
import Security
import SonioxClient

public struct KeychainStore: Sendable {
    public static let standard = KeychainStore(service: "app.subveil.soniox")

    public enum ReadResult: Sendable, Equatable {
        case found(String)
        case notFound
        case failed(OSStatus)
    }

    public let service: String
    private let account = "api-key"

    public init(service: String) { self.service = service }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }

    /// Existence check that never needs the item's secret, so it never triggers the access prompt.
    public func exists() -> Bool {
        var q = base
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        Trace.log("keychain", "exists: status \(st)")
        return st == errSecSuccess
    }

    /// Reading the secret may block on a system "allow access" dialog — call off the main thread.
    public func read() -> ReadResult {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        switch st {
        case errSecSuccess:
            guard let d = out as? Data, let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
                Trace.log("keychain", "read: item present but empty/unreadable")
                return .notFound
            }
            Trace.log("keychain", "read: found key (\(s.count) chars)")
            return .found(s)
        case errSecItemNotFound:
            Trace.log("keychain", "read: not found (service \(service))")
            return .notFound
        default:
            Trace.log("keychain", "read: FAILED status \(st) — \(Self.message(st))")
            return .failed(st)
        }
    }

    public func load() -> String? {
        if case let .found(k) = read() { return k }
        return nil
    }

    @discardableResult
    public func save(_ key: String) -> Bool {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(q as CFDictionary, nil)
        Trace.log("keychain", "save: status \(st)")
        return st == errSecSuccess
    }

    public func delete() {
        let st = SecItemDelete(base as CFDictionary)
        Trace.log("keychain", "delete: status \(st)")
    }
}
