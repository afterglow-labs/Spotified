import XCTest

final class SpotifiedUITests: XCTestCase {
    @MainActor func testSpotifyBrowseSearchAndLocalSelection() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["SPOTIFIED_CATALOG_QA"] == "1", let origin = env["SPOTIFIED_QA_ORIGIN"],
              let password = env["SPOTIFIED_QA_PASSWORD"] else { throw XCTSkip("Use the isolated catalog QA server with its queue disabled.") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = env["SPOTIFIED_QA_USERNAME"]
        app.launch()
        let field = app.secureTextFields["serverPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(password)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseSongs"].waitForExistence(timeout: 20))
        select("Spotify", app)
        let selectors = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND enabled == true", "selectSpotify-"))
        XCTAssertTrue(selectors.firstMatch.waitForExistence(timeout: 30))
        selectors.firstMatch.tap()
        app.buttons["Save 1 locally"].tap()
        XCTAssertTrue(app.buttons["saveSpotifySelection"].waitForExistence(timeout: 5))
        app.buttons["saveSpotifySelection"].tap()
        XCTAssertTrue(app.staticTexts["Added to Downloads. Your server will save the selected music."].waitForExistence(timeout: 15))
        app.buttons["spotifyBrowse"].tap()
        app.buttons["Search Spotify"].tap()
        let search = app.textFields["spotifySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Linkin Park\n")
        XCTAssertTrue(selectors.firstMatch.waitForExistence(timeout: 30))
        capture(app, "Spotify search and account browser")
    }

    @MainActor func testDeleteLibraryContentAndMiniPlayerTransport() async throws {
        continueAfterFailure = false
        guard let origin = ProcessInfo.processInfo.environment["SPOTIFIED_DELETE_FIXTURE"],
              URL(string: origin)?.host == "127.0.0.1" else { throw XCTSkip("Requires the disposable local deletion fixture.") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = "fixture-user"
        app.launch()
        let field = app.secureTextFields["serverPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("fixture-password")
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browsePlaylists"].waitForExistence(timeout: 15))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 1) { notNow.tap() }
        }
        app.buttons["browsePlaylists"].tap()
        app.staticTexts["QA deletion playlist"].tap()
        app.buttons["playCollection"].tap()
        let nowPlaying = app.buttons["nowPlaying"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 10))
        XCTAssertEqual(nowPlaying.value as? String, "Opening Song")
        app.buttons["miniNext"].tap()
        XCTAssertEqual(nowPlaying.value as? String, "Second Song")
        XCTAssertFalse(app.buttons["miniNext"].isEnabled)
        app.buttons["miniPrevious"].tap()
        if nowPlaying.value as? String == "Second Song" { app.buttons["miniPrevious"].tap() }
        XCTAssertEqual(nowPlaying.value as? String, "Opening Song")
        app.buttons["Delete playlist"].tap()
        app.alerts.firstMatch.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["playCollection"].exists)
        app.buttons["Delete playlist"].tap()
        app.alerts.firstMatch.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["No playlists yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(nowPlaying.exists)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["browseSongs"].tap()
        app.buttons["Details for Opening Song"].tap()
        let delete = app.buttons["Delete from server"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.alerts.firstMatch.buttons["Delete"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nowPlaying)
        await fulfillment(of: [gone], timeout: 12)
        XCTAssertFalse(app.buttons["Details for Opening Song"].exists)
        XCTAssertTrue(app.buttons["Details for Second Song"].exists)
    }

    @MainActor func testRemoteLibraryPlayback() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["SPOTIFIED_QA_PLAYBACK"] == "1", let origin = env["SPOTIFIED_QA_ORIGIN"], let password = env["SPOTIFIED_QA_PASSWORD"] else { throw XCTSkip("Enable a server playback check explicitly.") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = env["SPOTIFIED_QA_USERNAME"]
        app.launch()
        let field = app.secureTextFields["serverPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(password)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseSongs"].waitForExistence(timeout: 20))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        app.buttons["browseSongs"].tap()
        let song = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "play-track-")).firstMatch
        XCTAssertTrue(song.waitForExistence(timeout: 10)); song.tap()
        XCTAssertTrue(app.buttons["nowPlaying"].waitForExistence(timeout: 10))
        app.buttons["nowPlaying"].tap()
        let elapsed = app.staticTexts["playbackElapsed"]
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label != %@", "0:00"), object: elapsed)
        await fulfillment(of: [advancing], timeout: 25)
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "Pause")
        capture(app, "Streaming WSL library")
        app.buttons["playerPlayPause"].tap()
    }

    @MainActor func testArtistsAlbumsAndServerStreaming() async throws {
        continueAfterFailure = false
        guard let origin = ProcessInfo.processInfo.environment["SPOTIFIED_LIBRARY_FIXTURE"] else { throw XCTSkip("Start the library playback fixture.") }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = "fixture-user"
        app.launch()
        let password = app.secureTextFields["serverPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 10)); password.tap(); password.typeText("fixture-password")
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseArtists"].waitForExistence(timeout: 10))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        app.swipeUp()
        app.buttons["artist-alpha artist"].tap()
        XCTAssertTrue(app.navigationBars["Alpha Artist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First Album"].exists)
        XCTAssertTrue(app.staticTexts["Second Album"].exists)
        XCTAssertFalse(app.staticTexts["Opening Song"].exists, "Choosing an artist must show albums first.")
        capture(app, "Artist albums")
        app.buttons["sortLibrary"].tap()
        app.buttons["Name A–Z"].tap()
        app.buttons["sortLibrary"].tap()
        app.buttons["Newest release"].tap()
        let albums = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "album-"))
        XCTAssertTrue(albums.element(boundBy: 0).label.contains("Second Album"))
        app.staticTexts["First Album"].tap()
        XCTAssertTrue(app.buttons["playCollection"].waitForExistence(timeout: 5))
        let songs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "play-track-"))
        XCTAssertEqual(songs.count, 3)
        XCTAssertTrue(songs.element(boundBy: 0).label.contains("Opening Song"))
        XCTAssertTrue(songs.element(boundBy: 1).label.contains("Second Song"))
        XCTAssertTrue(songs.element(boundBy: 2).label.contains("Disc Two Song"))
        func receipt() async throws -> [String: Int] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/test/receipt")!)
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        let before = try await receipt()
        songs.element(boundBy: 0).tap()
        let pause = app.buttons["miniPlayPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: pause)
        await fulfillment(of: [playing], timeout: 20)
        app.buttons["nowPlaying"].tap()
        XCTAssertTrue(app.navigationBars["Now playing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Streaming from your server"].exists)
        let progress = app.sliders["Playback position"]
        XCTAssertTrue(progress.exists)
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotEqual(app.staticTexts["playbackElapsed"].label, "0:00", "The player clock must advance while streamed audio plays.")
        progress.adjust(toNormalizedSliderPosition: 0.5)
        try await Task.sleep(for: .seconds(1))
        let time = app.staticTexts["playbackElapsed"].label.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(time.count, 2)
        XCTAssertGreaterThanOrEqual(time[0] * 60 + time[1], 8)
        let originalTime = app.staticTexts["playbackElapsed"].label
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        app.activate()
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "Pause")
        XCTAssertNotEqual(app.staticTexts["playbackElapsed"].label, originalTime)
        let direct = try await receipt()
        XCTAssertGreaterThan(try XCTUnwrap(direct["original_ranges"]), try XCTUnwrap(before["original_ranges"]))
        XCTAssertEqual(direct["playback"], before["playback"], "Vorbis must play without preparing a server transcode.")
        capture(app, "Native server playback")
        app.buttons["playerPlayPause"].tap()
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "Play")
        app.buttons["playerNext"].tap()
        XCTAssertTrue(app.staticTexts["Second Song"].waitForExistence(timeout: 10))
        let nextPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Pause"), object: app.buttons["playerPlayPause"])
        await fulfillment(of: [nextPlaying], timeout: 20)
        progress.adjust(toNormalizedSliderPosition: 0.4)
        let beforeBackground = app.staticTexts["playbackElapsed"].label
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(3))
        app.activate()
        XCTAssertEqual(app.buttons["playerPlayPause"].label, "Pause")
        XCTAssertNotEqual(app.staticTexts["playbackElapsed"].label, beforeBackground, "Playback must continue while the app is in the background.")
        let lossless = try await receipt()
        XCTAssertGreaterThan(try XCTUnwrap(lossless["playback"]), try XCTUnwrap(direct["playback"]), "FLAC still uses the server's Apple Lossless path.")
        app.buttons["playerPlayPause"].tap()
    }

    @MainActor func testSpotifyAuthorizationRoundTripOnWSL() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPOTIFIED_QA_AUTH_FLOW"] == "1", let origin = environment["SPOTIFIED_QA_ORIGIN"],
              let password = environment["SPOTIFIED_QA_PASSWORD"] else { throw XCTSkip("Enable the authorized WSL sign-in check explicitly.") }
        let username = environment["SPOTIFIED_QA_USERNAME"] ?? "test-user"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var signIn = URLRequest(url: URL(string: origin + "/api/session")!)
        signIn.httpMethod = "POST"
        signIn.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: signIn)
        func state() async throws -> [String: Any] {
            let (data, _) = try await session.data(from: URL(string: origin + "/api/state")!)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let before = try await state()
        let jobs = before["jobs"] as? [[String: Any]] ?? []
        guard !jobs.contains(where: { ["queued", "running"].contains($0["status"] as? String ?? "") }) else {
            throw XCTSkip("The server is busy; leave the user's work running.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = username
        app.launchEnvironment["SPOTIFIED_TEST_CALLBACK_PORT"] = "0"
        app.launch()
        let field = app.secureTextFields["serverPassword"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(password)
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseAlbums"].waitForExistence(timeout: 15))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        select("Settings", app)
        XCTAssertTrue(app.buttons["settings-Request pacing"].waitForExistence(timeout: 5))
        app.swipeUp(); app.buttons["manageSpotify"].tap()
        app.buttons["spotifySignIn"].tap()
        var pending: [String: Any]?
        for _ in 0..<20 {
            let current = try await state()
            pending = (current["jobs"] as? [[String: Any]])?.first { $0["kind"] as? String == "login" && $0["login_url"] != nil }
            if pending != nil { break }
            try await Task.sleep(for: .seconds(1))
        }
        let login = try XCTUnwrap(pending)
        let authorization = try XCTUnwrap(URLComponents(string: try XCTUnwrap(login["login_url"] as? String)))
        let items = try XCTUnwrap(authorization.queryItems)
        let stateValue = try XCTUnwrap(items.first { $0.name == "state" }?.value)
        let redirect = try XCTUnwrap(items.first { $0.name == "redirect_uri" }?.value)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "The system Spotify sign-in sheet must open.")
        let loginField = app.webViews.textFields.firstMatch
        XCTAssertTrue(loginField.waitForExistence(timeout: 30), "Spotify must show its sign-in field, not a blank or rejected authorization page.")
        XCTAssertTrue(loginField.isHittable)
        capture(app, "Spotify sign-in sheet")
        var callback = try XCTUnwrap(URLComponents(string: redirect))
        callback.queryItems = [URLQueryItem(name: "state", value: stateValue), URLQueryItem(name: "error", value: "access_denied")]
        let (_, response) = try await session.data(from: callback.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(app.staticTexts["Spotify sign-in was declined. Your previous credentials have been kept."].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["spotifySignIn"].isEnabled)
        app.buttons["spotifyCheck"].tap()
        XCTAssertTrue(app.staticTexts["Spotify connected. Your credentials are saved on this server."].waitForExistence(timeout: 30))
        capture(app, "Spotify connection verified on WSL")
    }

    @MainActor func testManageSpotifyConnectionOnFixture() async throws {
        continueAfterFailure = false
        guard let origin = ProcessInfo.processInfo.environment["SPOTIFIED_FIXTURE_ORIGIN"] else { throw XCTSkip("Start the loopback fixture.") }
        var reset = URLRequest(url: URL(string: origin + "/test/reset")!)
        reset.httpMethod = "POST"; _ = try await URLSession.shared.data(for: reset)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = "fixture-user"
        app.launchEnvironment["SPOTIFIED_TEST_CALLBACK_PORT"] = "0"
        app.launch()
        let password = app.secureTextFields["serverPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 10)); password.tap(); password.typeText("fixture-password")
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseAlbums"].waitForExistence(timeout: 10))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        select("Settings", app)
        XCTAssertTrue(app.buttons["settings-Request pacing"].waitForExistence(timeout: 5))
        app.swipeUp()
        app.buttons["manageSpotify"].tap()
        XCTAssertTrue(app.buttons["spotifySignIn"].waitForExistence(timeout: 5))
        app.buttons["spotifyCheck"].tap()
        XCTAssertTrue(app.staticTexts["Spotify connection checked on server"].waitForExistence(timeout: 10))
        app.buttons["spotifySignIn"].tap()
        XCTAssertTrue(app.buttons["spotifyCancel"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["spotifySignIn"].isEnabled)
        capture(app, "Manage Spotify connection")
        app.buttons["spotifyCancel"].tap()
        XCTAssertTrue(app.staticTexts["Cancelled on fixture server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["spotifySignIn"].isEnabled)
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/test/receipt")!)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let writes = try XCTUnwrap(receipt["writes"] as? [[String: Any]])
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual((writes[0]["body"] as? [String: Any])?["mode"] as? String, "check")
        XCTAssertEqual((writes[1]["body"] as? [String: Any])?["mode"] as? String, "client")
        XCTAssertTrue((writes[2]["path"] as? String)?.hasSuffix("/cancel") == true)
    }

    @MainActor func testNativeQueueActionsAndSettingsOnFixture() async throws {
        continueAfterFailure = false
        guard let origin = ProcessInfo.processInfo.environment["SPOTIFIED_FIXTURE_ORIGIN"] else { throw XCTSkip("Start the loopback fixture for mutation tests.") }
        var reset = URLRequest(url: URL(string: origin + "/test/reset")!)
        reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = "fixture-user"
        app.launch()
        let password = app.secureTextFields["serverPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap(); password.typeText("fixture-password")
        app.buttons["connectButton"].tap()
        XCTAssertTrue(app.buttons["browseAlbums"].waitForExistence(timeout: 10))
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        app.buttons["addDownload"].tap()
        let links = app.textFields["downloadLinks"].exists ? app.textFields["downloadLinks"] : app.textViews["downloadLinks"]
        links.tap(); links.typeText("https://open.spotify.com/track/fixture")
        app.swipeUp()
        app.buttons["submitDownload"].tap()
        let track = app.staticTexts["Fixture track"]
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        XCTAssertTrue(app.links["source-link-0"].exists, "Source links must appear directly in the download list.")
        app.buttons["copy-source-0"].tap()
        XCTAssertTrue(app.buttons["copy-source-0"].label.contains("Copied"))
        XCTAssertEqual(app.state, .runningForeground, "Copying a source must not open its URL.")
        app.buttons["View details"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Download details"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground, "Viewing details must not open the source URL.")
        app.buttons["cancelJob"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Cancel download", "cancelJob")).firstMatch.tap()
        let restart = app.buttons["restartJob"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(restart.waitForExistence(timeout: 10), "Restart must also be available directly in history.")
        restart.tap()
        XCTAssertTrue(app.buttons["Restart queued"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["restartJob"].isEnabled)
        capture(app, "Visible source links and restart")
        select("Settings", app)
        app.buttons["settings-Request pacing"].tap()
        app.steppers.firstMatch.buttons["Increment"].tap()
        app.buttons["saveSettings"].tap()
        XCTAssertTrue(app.buttons["settings-Request pacing"].waitForExistence(timeout: 10))
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/test/receipt")!)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let writes = try XCTUnwrap(receipt["writes"] as? [[String: Any]])
        XCTAssertEqual(writes.count, 4)
        XCTAssertEqual(writes[0]["path"] as? String, "/api/jobs")
        XCTAssertTrue((writes[1]["path"] as? String)?.hasSuffix("/cancel") == true)
        XCTAssertTrue((writes[2]["path"] as? String)?.hasSuffix("/restart") == true)
        XCTAssertEqual(writes[3]["path"] as? String, "/api/settings")
        XCTAssertEqual((receipt["settings"] as? [String: Any])?["FETCH_DELAY"] as? Double, 2.5)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor func testNativeServerControl() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["SPOTIFIED_QA_ORIGIN"], let password = environment["SPOTIFIED_QA_PASSWORD"] else {
            throw XCTSkip("Set the private QA server environment before running this integration test.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["SPOTIFIED_TEST_ORIGIN"] = origin
        app.launchEnvironment["SPOTIFIED_TEST_USERNAME"] = environment["SPOTIFIED_QA_USERNAME"] ?? "test-user"
        app.launch()
        XCTAssertEqual(app.webViews.count, 0)
        let passwordField = app.secureTextFields["serverPassword"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 10))
        capture(app, "Native login")
        passwordField.tap(); passwordField.typeText(password)
        app.buttons["connectButton"].tap()
        let albums = app.buttons["browseAlbums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 30), app.debugDescription)
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let notNow = owner.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 2) { notNow.tap() }
        }
        XCTAssertEqual(app.webViews.count, 0, "The client must render native controls, not a web view.")
        capture(app, "Native library")
        albums.tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        app.navigationBars["Albums"].buttons.element(boundBy: 0).tap()
        app.buttons["browseArtists"].tap()
        XCTAssertTrue(app.navigationBars["Artists"].waitForExistence(timeout: 5))
        app.navigationBars["Artists"].buttons.element(boundBy: 0).tap()
        app.buttons["browsePlaylists"].tap()
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        app.navigationBars["Playlists"].buttons.element(boundBy: 0).tap()
        app.buttons["addDownload"].tap()
        XCTAssertTrue(app.textFields["downloadLinks"].waitForExistence(timeout: 5) || app.textViews["downloadLinks"].exists)
        XCTAssertTrue(app.buttons["submitDownload"].exists)
        XCTAssertFalse(app.buttons["submitDownload"].isEnabled)
        capture(app, "Native add download")
        app.buttons["Cancel"].tap()
        select("Downloads", app)
        XCTAssertTrue(app.staticTexts["Downloads run on your server"].waitForExistence(timeout: 5))
        capture(app, "Native downloads")
        select("Settings", app)
        app.buttons["settings-Request pacing"].tap()
        XCTAssertTrue(app.staticTexts["Between requests"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveSettings"].isEnabled)
        capture(app, "Native pacing")
        app.navigationBars["Request pacing"].buttons.element(boundBy: 0).tap()
        app.buttons["accountButton"].tap()
        XCTAssertTrue(app.staticTexts["appVersion"].waitForExistence(timeout: 5))
        capture(app, "Native account")
        app.buttons["Done"].tap()
        select("Library", app)
        XCTAssertEqual(app.webViews.count, 0)
    }

    @MainActor private func select(_ title: String, _ app: XCUIApplication) {
        if app.tabBars.buttons[title].exists { app.tabBars.buttons[title].tap() }
        else { app.buttons[title].firstMatch.tap() }
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
