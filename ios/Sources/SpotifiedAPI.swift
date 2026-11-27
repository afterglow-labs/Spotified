import Foundation
import AVFoundation

enum ClientError: LocalizedError {
    case message(String), signedOut
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .signedOut: return "Your server session expired. Sign in again."
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class SpotifiedAPI {
    let address: ServerAddress
    private let session: URLSession
    private var cookie: HTTPCookie?
    private var csrfToken = ""

    init(address: ServerAddress, configuration: URLSessionConfiguration = .ephemeral) {
        self.address = address
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel(); cookie = nil; csrfToken = "" }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: address.url)?.absoluteURL, address.contains(url) else {
            throw ClientError.message("Invalid server resource.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie { request.setValue("spotified_session=" + cookie.value, forHTTPHeaderField: "Cookie") }
        if method != "GET" {
            request.setValue(address.origin, forHTTPHeaderField: "Origin")
            request.setValue(csrfToken, forHTTPHeaderField: "X-Spotified-Token")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw ClientError.message("Invalid server response.") }
        if http.statusCode == 401 { throw ClientError.signedOut }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ClientError.message(detail ?? "Server request failed (\(http.statusCode)).")
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        if type != ServerSettings.self { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do { return try decoder.decode(type, from: data) }
        catch { throw ClientError.message("The server returned an unexpected response. Refresh or check the server version.") }
    }

    func login(username: String, password: String) async throws {
        let (data, _) = try await send(request("/api/health"))
        guard (try? JSONDecoder().decode([String: String].self, from: data))?["service"] == "spotified" else {
            throw ClientError.message("This address is not a Spotified server.")
        }
        var login = try request("/api/session", method: "POST")
        login.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let response: HTTPURLResponse
        do { response = try await send(login).1 }
        catch ClientError.signedOut { throw ClientError.message("The username or password is incorrect.") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        guard let sessionCookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: address.url).first(where: { $0.name == "spotified_session" }),
              address.url.scheme != "https" || sessionCookie.isSecure else {
            throw ClientError.message("The server did not provide a secure login session.")
        }
        cookie = sessionCookie
    }

    func state() async throws -> ServerState {
        let value = try decode(ServerState.self, await send(request("/api/state")).0)
        csrfToken = value.csrfToken
        return value
    }
    func library() async throws -> MusicLibrary { try decode(MusicLibrary.self, await send(request("/api/files")).0) }
    func deleteLibraryFiles(_ ids: [String]) async throws -> LibraryDeletionResult {
        try decode(LibraryDeletionResult.self, await send(request("/api/library/delete", method: "POST", body: ["ids": ids])).0)
    }
    func spotify(_ catalog: SpotifyCatalogRequest, offset: Int = 0, refresh: Bool = false) async throws -> SpotifyCatalogPage {
        try decode(SpotifyCatalogPage.self, await send(request(catalog.path(offset: offset, refresh: refresh))).0)
    }
    func saveSpotify(uris: [String], format: String, quality: String, bitrate: String) async throws {
        _ = try await state()
        _ = try await send(request("/api/spotify/import", method: "POST", body: [
            "uris": uris, "format": format, "quality": quality, "bitrate": bitrate
        ]))
    }
    func playbackItem(_ track: MusicTrack) async throws -> AVPlayerItem {
        guard let cookie, let divider = track.id.firstIndex(of: "/") else { throw ClientError.signedOut }
        let root = String(track.id[..<divider])
        let path = String(track.id[track.id.index(after: divider)...])
        if ["ogg", "oga"].contains((path as NSString).pathExtension.lowercased()), track.size > 0 {
            var parts = URLComponents()
            parts.path = "/media"
            parts.queryItems = [URLQueryItem(name: "root", value: root), URLQueryItem(name: "path", value: path)]
            // The server uses form-style query decoding, where an unescaped plus means a space.
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let path = parts.string else { throw ClientError.message("Invalid media address.") }
            var media = try request(path)
            media.setValue("audio/ogg", forHTTPHeaderField: "Accept")
            let source = VorbisAsset(request: media, byteCount: track.size)
            let supported = try await withTaskCancellationHandler {
                try await source.prepare()
            } onCancel: { source.cancel() }
            try Task.checkCancellation()
            if supported { return source.playerItem() }
        }
        _ = try await state()
        struct Reply: Decodable { let url: String }
        let reply = try decode(Reply.self, await send(request("/api/playback", method: "POST", body: [
            "root": root, "path": path
        ])).0)
        guard reply.url.hasPrefix("/media?") || reply.url.hasPrefix("/stream/"),
              let url = URL(string: reply.url, relativeTo: address.url)?.absoluteURL, address.contains(url) else {
            throw ClientError.message("The server returned an invalid playback address.")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: [cookie]])
        return AVPlayerItem(asset: asset)
    }
    func settings() async throws -> ServerSettings { try decode(ServerSettings.self, await send(request("/api/settings")).0) }
    func saveSettings(_ changes: [String: Any]) async throws -> ServerSettings {
        _ = try await state()
        return try decode(ServerSettings.self, await send(request("/api/settings", method: "POST", body: changes)).0)
    }
    func queue(urls: String, format: String, quality: String, bitrate: String, preview: Bool) async throws {
        _ = try await state()
        _ = try await send(request("/api/jobs", method: "POST", body: ["urls": urls, "format": format, "quality": quality, "bitrate": bitrate, "preview": preview]))
    }
    func jobAction(id: String, action: String) async throws {
        guard id.count == 32, id.allSatisfy({ "0123456789abcdef".contains($0) }), ["cancel", "restart"].contains(action) else {
            throw ClientError.message("Invalid queue action.")
        }
        _ = try await state()
        _ = try await send(request("/api/jobs/\(id)/\(action)", method: "POST", body: [:]))
    }
    func spotifyLogin(check: Bool, callbackPort: Int = 4381) async throws -> DownloadJob {
        _ = try await state()
        struct Reply: Decodable { let job: DownloadJob }
        return try decode(Reply.self, await send(request("/api/login", method: "POST", body: [
            "mode": check ? "check" : "client", "callback_port": callbackPort
        ])).0).job
    }
    func spotifyCallback(id: String, url: String) async throws {
        guard id.count == 32, id.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ClientError.message("Invalid Spotify sign-in.")
        }
        _ = try await state()
        _ = try await send(request("/api/jobs/\(id)/spotify-callback", method: "POST", body: ["url": url]))
    }
    func artwork(_ path: String) async throws -> Data {
        guard path.hasPrefix("/artwork?") else { throw ClientError.message("Invalid artwork resource.") }
        return try await send(request(path)).0
    }
}
