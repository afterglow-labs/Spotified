# Spotified for iPhone and iPad

A native SwiftUI remote client for the Spotified server. Its connection/account flow, native forms and navigation follow [afterglow-labs/odysseus-ios, branch main](https://github.com/afterglow-labs/odysseus-ios). The phone sends API commands to the server; WSL runs the downloader and stores all audio files. Jobs continue after the app closes.

Version **0.2.0 (2)** replaced the initial WKWebView client with native screens. The library, queue, and settings remain native. Version **0.3.0 (4)** added Spotify authorization in a system browser sheet. Version **0.4.0 (5)** adds artist → album → song browsing and native server streaming. Download jobs and the permanent music library stay on the server; the phone buffers audio for playback.

- Artists open their albums, and albums open songs in disc/track order. Sort by name, release year, or recently added; search artist, album, and song tags.
- Stream a song, album, or playlist with play/pause, seeking, next/previous, shuffle, a mini-player, AirPlay, background audio, and lock-screen controls.
- Browse your Spotify playlists, liked songs, saved albums, and followed artists; search songs, albums, playlists, and artists. Select songs or whole collections and choose **Save locally** to queue server downloads.
- Add Spotify links with source/conversion quality choices; preview metadata on the server if desired.
- View queue progress, history, source links, and logs. Cancel or restart eligible jobs on the server.
- Edit audio quality, artist/album organization, playlist layout, artwork, lyrics, and request pacing.
- Saved server login in Keychain; connection/account screen and Afterglow (default) or Light appearances. The retired Dark preference migrates to Afterglow when the app starts.
- iPhone tab navigation and iPad sidebar navigation. Requires iOS 17 or later.

## Source links and restart in 0.2.1 (3)

Every download card now shows its saved source links with Open and Copy actions. Canceled, interrupted, failed, and partial jobs expose **Restart on server** directly in the list and in their details. While a retry is queued or running, the original card shows **Restart queued** and disables duplicate submissions. Restart preserves the saved source/audio choices and skips existing files on the server.

## Spotify sign-in in 0.3.0 (4)

Open **Settings → Manage Spotify connection → Sign in / switch Spotify account**. Complete Spotify's form in the sheet. The app returns the authorization to the selected server, which verifies and saves the new credentials. Keep Spotified open during sign-in. Closing the management screen before submitting authorization cancels that attempt.

The same screen offers **Check Spotify connection**, the latest connection result, and **Cancel pending connection**. Sign-in waits behind active server downloads; finish or cancel those first. Failed or declined authorization keeps the existing saved credentials.

`SpotifyLoginReceiver` listens only on the device's loopback address while the Spotify sheet is open. The callback is checked against its exact destination and random state, then sent through the authenticated, CSRF-protected server API. The server keeps the PKCE verifier and exchanges the single-use code. Authorization URLs and codes are excluded from persisted history. This uses Spotify's supported [loopback redirect](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri) flow and Apple's [system browser sheet](https://developer.apple.com/documentation/safariservices/sfsafariviewcontroller). The WSL server must include this update; older servers only support desktop authorization.

## Streaming in 0.4.0 (5)

Choose **Library → Artist → Album**, then tap a song, **Play**, or **Shuffle**. Tap the mini-player to open Now Playing. Playback continues while the phone is locked or another app is open. The server must remain reachable through Tailscale.

The server serves compatible media directly and prepares Ogg/Opus as temporary AAC 320 kbps HLS for the native player. FLAC uses a temporary lossless ALAC stream. Source files, tags, and artwork are unchanged. Temporary playback data is limited to 512 MiB with at most two simultaneous transcodes, and is cleaned up on eviction or server shutdown. This is streaming playback; it does not add an offline audio library or export on the phone.

## Install

Version **0.5.0 (7)** includes the Spotify tab, Afterglow default appearance, and the updated music icon. Browsing requires the matching server update. It reuses the Spotify account already connected to that server. See [catalog behavior and API](../docs/SPOTIFY-CATALOG.md).

The signed IPA is `ios/.build/Export/Spotified.ipa`. A versioned copy is delivered to the registered iPhone through Tailscale Taildrop, matching the existing Odysseus/Feather workflow. Receive the IPA in Tailscale and import it into Feather to sign/install using your configured identity. Keep bundle identifier `com.afterglowlabs.spotified.ios`.

The Afterglow Labs ad hoc profile includes the registered iPhone 16 Pro. A successful archive, transfer, or simulator test does not establish installation on a physical device. When a paired, unlocked phone is available to Xcode, the exported app can instead be installed with `xcrun devicectl device install app`.

Connect Tailscale on the phone and sign in with the existing Spotified server account. The default address is `https://nibiru-darklight-1.osiris-cosmological.ts.net:8443`. No password is embedded in the app or source.

## Build

Requires Xcode and XcodeGen.

```sh
python3 ios/build.py simulator
python3 ios/build.py archive
```

The archive command uses the existing Afterglow Labs ad hoc profile and a matching distribution certificate in Keychain. Override `--identity`, `--profile`, and `--team` for another signing setup. It does not publish to TestFlight or the App Store. Generated projects, build products, and private QA settings are ignored by Git.

## Architecture

`SpotifiedAPI` uses an ephemeral URLSession with server-scoped cookies, TLS validation, redirect rejection, and CSRF tokens on mutations. Mutations are never automatically retried. Credentials are sent only at login. Artwork is fetched for display. Playback requests a same-server media URL and gives AVPlayer the server-scoped session cookie; audio streams are authenticated and cannot be fetched anonymously.

`ServerController` owns connection, queue, library and settings state. Foreground polling stops when the app leaves the foreground. Stale responses cannot overwrite a switched connection or a newer refresh after an action. Settings send only changed fields and keep unsaved drafts local until Save.

`LibraryViews`, `DownloadViews`, and `SettingsViews` render native SwiftUI controls. `MusicPlayer` owns AVPlayer, its album/playlist queue, the playback audio session, and system media controls. `PlayerViews` provides the mini-player and Now Playing screen. `SpotifyConnectionView` manages Spotify authorization and connection checks through the server API; the server performs credential storage and all downloads.

## Tests

`SpotifiedTests` checks URL validation, Keychain isolation, cookie/CSRF-authenticated queue commands, settings changes including explicit zero/false, expired sessions, mutation failure without automatic retries, and rejection of media/external URLs as artwork.

`SpotifiedUITests` checks native navigation against a real WSL server without creating live jobs. It asserts that no WKWebView exists. A second flow submits, cancels, restarts and changes settings against the isolated loopback fixture, then verifies exact server-side command receipts. The fixture never contacts Spotify or downloads music.

Start the fixture before running mutation UI tests:

```sh
python3 ios/scripts/fixture_server.py --port 18769
```

Set `SPOTIFIED_FIXTURE_ORIGIN=http://127.0.0.1:18769` in the test runner environment. Real-server tests use `SPOTIFIED_QA_ORIGIN`, `SPOTIFIED_QA_USERNAME`, and `SPOTIFIED_QA_PASSWORD`. Keep real credentials in a private `.xctestrun` file under `.build`; never put them in the shared scheme. Run fixture tests serially because they share fixture state. Simulator builds must remain ad hoc signed for Keychain access.

Final validation: nine unit/API tests and two iPhone UI flows passed in `ios/.build/Native-WSL-QA-3.xcresult`; the WSL navigation flow also passed on iPad in `ios/.build/Native-iPad-QA-1.xcresult`. Screenshots: [iPhone library](../docs/qa/ios-native-library.png), [download form](../docs/qa/ios-native-add-download.png), [iPad library](../docs/qa/ios-native-ipad-library.png). The signed version 0.2.0 (2) IPA was transferred to the registered iPhone 16 Pro via Taildrop. Physical-device installation has not been observed.

Version 0.2.1 (3): all nine unit/API tests and both UI flows passed in `ios/.build/Sources-Restart-QA-3.xcresult`. The fixture flow verifies source links and Copy directly on the download card, independent tap targets, restart directly in history, and disabled duplicate restarts. Screenshot: [source links and restart](../docs/qa/ios-source-links-restart.png). The signed IPA was delivered through Taildrop; physical installation remains unobserved.

Version 0.3.0 (4): twelve unit/API tests passed, including the actual loopback callback receiver, invalid-state rejection, and authenticated callback forwarding. Existing queue/settings and WSL navigation flows passed; the new management fixture flow passed in `ios/.build/Spotify-Login-QA-2.xcresult`. Live WSL checks opened the actual [Spotify sign-in form](../docs/qa/ios-spotify-sign-in.png), relayed a declined authorization from the simulator to the server, and checked saved credentials. The refusal seen during one check led to the server access-point failover fix documented in `docs/WSL.md`; deliberately selecting the refusing endpoint first now recovers and authenticates. Completing a new Spotify account authorization still requires user interaction.

The signed `Spotified-0.3.0-4.ipa` was delivered to the iPhone via Taildrop on November 14 and copied to the Mac Desktop. The private hosted IPA checksum was verified. Physical installation is not observed.

Final live check after the failover fix: `ios/.build/Spotify-Login-WSL-QA-4.xcresult` passed the complete native flow: open Spotify's usable email sign-in field, receive and relay a declined callback, return to the native controls, then successfully verify the saved WSL Spotify connection.

## Version 0.4.0 validation

The WSL candidate image passes all **135 Python tests**; the Mac runs **134 with one existing Vorbis encoder skip**. New tests exercise authenticated playback, CSRF rejection, traversal prevention, byte ranges, Ogg HLS preparation/cache cleanup, and sample-identical FLAC-to-ALAC playback.

All **15 native unit/API tests** passed. `Library-Playback-QA-6.xcresult` verifies artist → album → song navigation, album-year sorting, multidisc order, authenticated Ogg streaming, lossless FLAC playback, seeking, next track, and playback while the app is in the background. `Library-Playback-WSL-QA-1.xcresult` passes the existing login-management, download/source/restart/settings, and navigation flows plus playback of actual WSL library audio using an isolated candidate server with the real media mounted read-only. It does not contact Spotify or modify the live download queue.

The signed **Spotified-0.4.0-5.ipa** is prepared in `ios/.build/Export` and on the Mac Desktop. Activating the server update and phone installation are separate steps; physical-device playback has not been observed.

The final iPad playback check passes in `Library-Playback-iPad-QA-2.xcresult`. Screenshots: [artist albums](../docs/qa/ios-artist-albums.png), [native playback](../docs/qa/ios-server-playback.png), and [iPad streaming WSL audio](../docs/qa/ios-ipad-server-playback.png).

## Version 0.5.0 validation

The Spotify catalog UI passed browsing, search, selection, and queue submission against an isolated WSL server with downloads disabled. Build 7 passed **19 unit/API tests**, including fresh-install and retired-theme migration, plus the existing native navigation UI flow against the loopback fixture. Results are in `Afterglow-Unit-7.xcresult` and `Afterglow-UI-7.xcresult` under `ios/.build` on the Mac. Screenshots: [Afterglow login](../docs/qa/ios-afterglow-login.png) and [Afterglow account](../docs/qa/ios-afterglow-account.png).

The signed `Spotified-0.5.0-7.ipa` is available under `ios/.build/Export` in the Windows checkout and Mac build workspace, with a copy on the Mac Desktop. Archive signature, bundle version, packaged icon, and ZIP integrity passed verification. The matching server update is staged pending the active download; physical iPhone installation has not been observed.
