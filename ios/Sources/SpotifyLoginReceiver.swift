import Foundation
import Network
import Observation

/// Receives Spotify's loopback redirect while its system browser sheet is open.
/// Only the authorization code is relayed to the authenticated server; PKCE stays there.
@MainActor @Observable final class SpotifyLoginReceiver {
    private(set) var callbackURL: String?
    private(set) var error: String?
    private(set) var port: UInt16 = 4381
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var redirect: URL?
    private var state = ""
    private var connections: [NWConnection] = []

    func start(port requestedPort: UInt16 = 4381) async throws -> UInt16 {
        stop(); callbackURL = nil; error = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { [weak self, weak listener] status in
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    switch status {
                    case .ready:
                        guard let port = listener?.port?.rawValue else { return }
                        self.port = port; let pending = self.ready; self.ready = nil; pending?.resume(returning: port)
                    case .failed:
                        let message = "Could not start Spotify sign-in on this device. Close another pending sign-in and try again."
                        self.error = message
                        let pending = self.ready; self.ready = nil
                        pending?.resume(throwing: ClientError.message(message)); self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.listener != nil, self.connections.count < 8 else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.start(queue: .main)
                    self.receive(connection, buffer: Data())
                    Task { @MainActor [weak self, weak connection] in
                        try? await Task.sleep(for: .seconds(10))
                        if let connection { self?.close(connection) }
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    func configure(authorizationURL: URL) throws {
        guard authorizationURL.scheme == "https", authorizationURL.host == "accounts.spotify.com", authorizationURL.path == "/authorize",
              let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems,
              let redirectText = items.first(where: { $0.name == "redirect_uri" })?.value,
              let redirect = URL(string: redirectText), redirect.scheme == "http", redirect.host == "127.0.0.1",
              redirect.port == Int(port), redirect.path == "/login", redirect.user == nil, redirect.password == nil,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
            throw ClientError.message("The server returned an unsupported Spotify sign-in. Update the server and try again.")
        }
        self.redirect = redirect; self.state = state
    }

    func accepts(_ url: URL) -> Bool {
        guard let redirect, url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port,
              url.path == redirect.path, url.user == nil, url.password == nil, url.fragment == nil,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        let states = query.filter { $0.name == "state" }
        let codes = query.filter { $0.name == "code" && !($0.value ?? "").isEmpty }
        let errors = query.filter { $0.name == "error" && !($0.value ?? "").isEmpty }
        return states.count == 1 && states[0].value == state && ((codes.count == 1 && errors.isEmpty) || (errors.count == 1 && codes.isEmpty))
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16000) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer; if let data { buffer.append(data) }
                guard buffer.count <= 16000, failure == nil else { self.close(connection); return }
                guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { self.close(connection) } else { self.receive(connection, buffer: buffer) }; return
                }
                let lines = request.components(separatedBy: "\r\n")
                let parts = (lines.first ?? "").split(separator: " ")
                let host = lines.first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard parts.count == 3, parts[0] == "GET", host == "127.0.0.1:\(self.port)",
                      let url = URL(string: "http://127.0.0.1:\(self.port)" + String(parts[1])), self.accepts(url), self.callbackURL == nil else {
                    self.reply(connection, status: "400 Bad Request", message: "This Spotify sign-in is not valid. Return to Spotified and try again."); return
                }
                self.callbackURL = url.absoluteString
                self.listener?.cancel(); self.listener = nil
                self.reply(connection, status: "200 OK", message: "Authorization received. Return to Spotified to check the server connection.")
            }
        }
    }

    private func reply(_ connection: NWConnection, status: String, message: String) {
        let body = Data("<!doctype html><meta name=viewport content='width=device-width'><title>Spotified</title><h1>Spotified</h1><p>\(message)</p>".utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }
    private func close(_ connection: NWConnection) { connection.cancel(); connections.removeAll { $0 === connection } }
    func stop() {
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        let pending = ready; ready = nil; pending?.resume(throwing: CancellationError())
        redirect = nil; state = ""
    }
}
