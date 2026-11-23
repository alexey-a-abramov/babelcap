import Foundation

public enum SonioxKeyVerifier {
    public enum Result: Sendable, Equatable {
        case valid
        case invalid(String)
        case unreachable(String)
    }

    /// Opens a throwaway stream and waits briefly: an immediate error response means a bad key / no balance.
    public static func verify(apiKey: String, model: String) async -> Result {
        var req = URLRequest(url: SonioxSession.endpoint)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let ws = URLSession(configuration: .default).webSocketTask(with: req)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        do {
            try await ws.send(.string(String(decoding: try SonioxConfig(model: model).jsonData(), as: UTF8.self)))
        } catch {
            return .unreachable(error.localizedDescription)
        }
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    while true {
                        let msg = try await ws.receive()
                        var data = Data()
                        switch msg {
                        case let .string(s): data = Data(s.utf8)
                        case let .data(d): data = d
                        @unknown default: break
                        }
                        if let r = try? SonioxResponse.decode(data), let code = r.errorCode {
                            return .invalid(SonioxError(code: code, message: r.errorMessage ?? "").localizedDescription)
                        }
                    }
                } catch {
                    return .unreachable(error.localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return .valid // no error within 2 s → accepted
            }
            let first = await group.next() ?? .valid
            group.cancelAll()
            return first
        }
    }
}
