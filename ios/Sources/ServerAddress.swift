import Foundation

struct ServerAddress: Equatable {
    static let defaultOrigin = "https://nibiru-darklight-1.osiris-cosmological.ts.net:8443"
    let url: URL
    var origin: String { url.absoluteString }

    init?(_ raw: String) {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              parts.scheme == "https" || (parts.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host))
        else { return nil }
        parts.path = ""
        parts.host = host.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        guard let url = parts.url else { return nil }
        self.url = url
    }

    func contains(_ candidate: URL) -> Bool {
        candidate.scheme == url.scheme && candidate.host?.lowercased() == url.host?.lowercased()
        && (candidate.port ?? (candidate.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    func endpoint(_ path: String) -> URL { url.appendingPathComponent(path) }
}
