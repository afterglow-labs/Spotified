import AppKit
import WebKit
import Security

let localServer = "http://127.0.0.1:8088"
let keychainService = "com.afterglowlabs.spotified.server"

enum LoginStore {
    static func query(_ origin: String, _ username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: origin + "|" + username]
    }
    static func read(_ origin: String, _ username: String) -> String? {
        var q = query(origin, username)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, origin: String, username: String) throws {
        let q = query(origin, username)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = q.merging(attributes) { _, new in new }
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

// Installer helper: receives credentials through stdin, never command arguments.
if CommandLine.arguments.contains("--store-login") {
    do {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let login = try JSONSerialization.jsonObject(with: data) as! [String: String]
        try LoginStore.save(login["password"]!, origin: login["server"]!, username: login["username"]!)
        UserDefaults.standard.set(login["server"], forKey: "server")
        UserDefaults.standard.set(login["username"], forKey: "username")
        print("Login saved in Keychain.")
        exit(0)
    } catch { fputs("Could not save login in Keychain.\n", stderr); exit(1) }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var statusLabel: NSTextField!
    var panel: NSPanel?
    var addressField = NSTextField()
    var usernameField = NSTextField()
    var passwordField = NSSecureTextField()
    var panelMessage = NSTextField(labelWithString: "")
    var origin = UserDefaults.standard.string(forKey: "server") ?? localServer
    var username = UserDefaults.standard.string(forKey: "username") ?? "corey"
    var generation = 0
    var connecting = false
    let network = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        createMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Spotified"
        window.subtitle = "by Afterglow Labs"
        window.minSize = NSSize(width: 760, height: 540)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 18/255, green: 8/255, blue: 32/255, alpha: 1)
        window.setFrameAutosaveName("SpotifiedMainWindow")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "connection")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = window.backgroundColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(webView)
        NSLayoutConstraint.activate([webView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), webView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), webView.topAnchor.constraint(equalTo: window.contentView!.topAnchor), webView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        statusLabel = NSTextField(wrappingLabelWithString: "Connecting to Spotified…")
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 16, weight: .regular)
        statusLabel.textColor = NSColor(srgbRed: 255/255, green: 242/255, blue: 233/255, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(statusLabel)
        NSLayoutConstraint.activate([statusLabel.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor), statusLabel.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor), statusLabel.widthAnchor.constraint(equalToConstant: 540)])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        connect(password: LoginStore.read(origin, username), remember: false)
    }

    func createMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let menu = NSMenu(); appItem.submenu = menu
        menu.addItem(withTitle: "About Spotified", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "Connection Settings…", action: #selector(showConnection), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Spotified", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit Spotified", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem); editItem.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editItem.submenu!.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let viewItem = NSMenuItem(); main.addItem(viewItem); viewItem.submenu = NSMenu(title: "View")
        viewItem.submenu!.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        NSApp.mainMenu = main
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Spotified", .credits: NSAttributedString(string: "by Afterglow Labs")])
    }
    @objc func reload() { connect(password: LoginStore.read(origin, username), remember: false) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }

    @objc func showConnection() {
        if panel != nil { return }
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Connect to Spotified"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; sheet.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: sheet.contentView!.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: sheet.contentView!.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: sheet.contentView!.topAnchor, constant: 20)])
        addressField = NSTextField(string: origin); usernameField = NSTextField(string: username)
        passwordField = NSSecureTextField(string: LoginStore.read(origin, username) ?? "")
        for (title, field) in [("Server", addressField), ("Username", usernameField), ("Password", passwordField)] {
            stack.addArrangedSubview(NSTextField(labelWithString: title)); stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        panelMessage = NSTextField(wrappingLabelWithString: "Your password is saved in macOS Keychain. Use HTTPS for a remote server.")
        panelMessage.font = .systemFont(ofSize: 11); stack.addArrangedSubview(panelMessage)
        let buttons = NSStackView(); buttons.orientation = .horizontal
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelConnection))
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(saveConnection)); connectButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(connectButton); stack.addArrangedSubview(buttons)
        panel = sheet; window.beginSheet(sheet)
    }
    @objc func cancelConnection() { if let panel { window.endSheet(panel); self.panel = nil } }
    static func validatedOrigin(_ raw: String) -> String? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              parts.port == nil || (1...65535).contains(parts.port!) else { return nil }
        var clean = parts; clean.path = ""; return clean.url?.absoluteString
    }
    @objc func saveConnection() {
        guard let address = Self.validatedOrigin(addressField.stringValue), !usernameField.stringValue.isEmpty, !passwordField.stringValue.isEmpty else {
            panelMessage.stringValue = "Enter a valid server origin, username, and password. Remote servers must use HTTPS."; return
        }
        origin = address; username = usernameField.stringValue
        let password = passwordField.stringValue
        cancelConnection(); connect(password: password, remember: true)
    }

    func connect(password: String?, remember: Bool) {
        connecting = true
        generation += 1; let current = generation
        webView.isHidden = true; statusLabel.isHidden = false
        statusLabel.stringValue = origin == localServer ? "Starting your music server…" : "Connecting to your music server…"
        let server = origin, user = username
        Task {
            defer { if current == generation { connecting = false } }
            do {
                let alreadyRunning = await healthy(server)
                if server == localServer && !alreadyRunning {
                    guard let script = Bundle.main.object(forInfoDictionaryKey: "SpotifiedStartScript") as? String else { throw failure("The local server launcher is missing.") }
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [script]
                    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Spotified")
                    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                    let logfile = logs.appendingPathComponent("server-start.log")
                    if !FileManager.default.fileExists(atPath: logfile.path) { FileManager.default.createFile(atPath: logfile.path, contents: nil) }
                    let output = try FileHandle(forWritingTo: logfile); try output.seekToEnd()
                    process.standardOutput = output; process.standardError = output; try process.run()
                    var ready = false
                    for _ in 0..<90 {
                        if current != generation { return }
                        if await healthy(server) { ready = true; break }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                    try? output.close()
                    if !ready { throw failure("The local server could not start. Check ~/Library/Logs/Spotified/server-start.log, then use View → Reload.") }
                }
                guard current == generation else { return }
                guard let password, !password.isEmpty else { statusLabel.stringValue = "Sign in to your Spotified server."; showConnection(); return }
                statusLabel.stringValue = "Signing in…"
                var request = URLRequest(url: URL(string: server + "/api/session")!); request.httpMethod = "POST"; request.timeoutInterval = 15
                request.setValue("Basic " + Data((user + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
                let (data, response) = try await network.data(for: request)
                guard current == generation else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    throw failure(message ?? "This server could not sign you in.")
                }
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in result[String(describing: item.key)] = String(describing: item.value) }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
                guard cookies.contains(where: {$0.name == "spotified_session"}) else { throw failure("The server did not provide a login session.") }
                for cookie in cookies { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                if remember { try LoginStore.save(password, origin: server, username: user) }
                UserDefaults.standard.set(server, forKey: "server"); UserDefaults.standard.set(user, forKey: "username")
                window.subtitle = server == localServer ? "by Afterglow Labs · This Mac" : "by Afterglow Labs · " + (URL(string: server)?.host ?? "Server")
                webView.load(URLRequest(url: URL(string: server)!))
            } catch {
                guard current == generation else { return }
                statusLabel.stringValue = error.localizedDescription + "\n\nOpen Spotified → Connection Settings to try again."
                showConnection(); panelMessage.stringValue = error.localizedDescription
            }
        }
    }
    func healthy(_ server: String) async -> Bool {
        var request = URLRequest(url: URL(string: server + "/api/health")!); request.timeoutInterval = 2
        guard let (data, response) = try? await network.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
        return value["service"] == "spotified"
    }
    func failure(_ message: String) -> NSError { NSError(domain: "Spotified", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let securityOrigin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, let server = URL(string: origin),
              securityOrigin.host == server.host, securityOrigin.protocol == server.scheme,
              securityOrigin.port == (server.port ?? (server.scheme == "https" ? 443 : 80)) else { return }
        if message.body as? String == "reauth" { if !connecting { reload() } }
        else { showConnection() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { statusLabel.isHidden = true; webView.isHidden = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { statusLabel.stringValue = error.localizedDescription + "\nUse View → Reload to retry." }
    func isServer(_ url: URL) -> Bool {
        guard let server = URL(string: origin) else { return false }
        return url.scheme == server.scheme && url.host == server.host && url.port == server.port
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if isServer(url) { decisionHandler(action.shouldPerformDownload ? .download : .allow) }
        else { if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.hasPrefix("attachment") == true
        decisionHandler(attachment || !response.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let save = NSSavePanel(); save.nameFieldStringValue = suggestedFilename
        save.beginSheetModal(for: window) { result in completionHandler(result == .OK ? save.url : nil) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; return nil
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
