import Foundation

/// Minimal Hugging Face Hub client: list files (with LFS sha256) and build download URLs.
public enum HuggingFace {
    nonisolated(unsafe) public static var base = URL(string: "https://huggingface.co")!

    public struct RemoteFile: Sendable, Hashable {
        public let path: String      // path inside the repo
        public let size: Int64
        public let sha256: String?   // LFS files only
    }

    struct TreeItem: Decodable {
        struct LFS: Decodable { let oid: String?; let size: Int64? }
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
    }

    /// All files under `path` (recursive).
    public static func listFiles(repo: String, path: String) async throws -> [RemoteFile] {
        var comps = URLComponents(url: base.appendingPathComponent("api/models/\(repo)/tree/main" + (path.isEmpty ? "" : "/\(path)")),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, resp) = try await URLSession.shared.data(from: comps.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face returned \(http.statusCode) for \(repo)"])
        }
        let items = try JSONDecoder().decode([TreeItem].self, from: data)
        return items.filter { $0.type == "file" }.map {
            RemoteFile(path: $0.path, size: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.oid)
        }
    }

    public static func downloadURL(repo: String, path: String) -> URL {
        let escaped = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(base.absoluteString)/\(repo)/resolve/main/\(escaped)")!
    }
}
