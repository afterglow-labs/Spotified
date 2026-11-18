# Review and improvements — 0.22.1

Reviewed the Python CLI, configuration/authentication flow, HTTP and stream handling, library/archive logic, packaging, and repository automation. Built Spotified's authenticated server, media library interface, and native Mac and iOS clients on top. Deployed the server to WSL2 and published a signed iOS installer privately within Tailscale. Docker startup, Spotify OAuth login, saved-login reconnection, and a live metadata preview were verified. No live audio download or Git push was performed during this validation.

## Fixed findings

| Priority | Finding | Change and coverage |
| --- | --- | --- |
| P1 | Interrupted stream retries reused the failed stream; early EOF was accepted as success. | Reacquire the stream after reconnecting, restart the file, verify bytes remaining after the consumed header, close streams, and delete incomplete output. Tests exercise truncation, recovery, and cancellation. |
| P1 | FFmpeg wrote directly to the destination; conversion failure could leave a partial final file. Fallback extensions could overwrite an existing file. | Convert to a sibling staging file and replace only on success; choose a free fallback filename. A real FFmpeg test preserves an existing destination after failure, then successfully converts generated audio. |
| P1 | Direct podcast downloads read `.content` before copying `.raw`, consuming the response; the copy helper could not handle streams. | Use chunked streaming with size checks and response cleanup. Fix byte/stream copying separately. Tests forbid accessing `.content` and reject truncated podcasts. |
| P1 | Shutdown deleted every root-level `.tmp` file, including files belonging to other programs. | Generate unique temporary names and track only files owned by this process. A regression test preserves an unrelated temporary file. |
| P1 | Stale archive entries caused deleted/empty audio files to be treated as downloaded. Reusing an initially empty archive object overwrote prior entries. | Require an existing nonempty target, prefer the newest usable matching entry, and switch to append after the first write. Sanitize tabs/newlines in archive fields. |
| P2 | A hard-coded flag disabled a configured client API, blocking search and user-library modes. | Honor an explicitly configured client ID; preserve the no-client metadata path. Configuration tests cover both states. Live authorization remains unverified. |
| P2 | Combining search filters called string methods on integer defaults. Invalid interactive selections raised errors or selected unintended entries. | Parse filters deterministically, honor the last repeated filter, and validate complete bounded selections before indexing. |
| P1 | The running profile waited only two seconds between tracks; librespot retried audio-key failures immediately and internal requests bypassed the API wait. | Adopt the linked fork's 30-second track gap, pace download HTTP/audio-key attempts with a shared lock, disable the hidden retry, back off 30/60/120 seconds in the personal preset, and honor HTTP Retry-After even after retry exhaustion. Offline tests exercise the real pinned audio-key implementation, redirects, concurrent requests, final-attempt 429s, and cancellation. |
| P2 | HTTP timeouts, empty/malformed JSON, connection failures, and malformed `Retry-After` values could break retry handling. Expected failures ignored server rate-limit delays. | Bounded retries for transient failures, numeric/date retry delays, and immediate handling of permanent client errors. Mocked HTTP tests cover these cases. |
| P2 | Recursive pagination could exceed Python's recursion limit. | Iterative pagination with result limits and repeated-URL detection; tested with 1,101 pages. |
| P2 | Missing bulk metadata or unavailable album children crashed parsing; album normalization overwrote the album type. | Preserve missing positions, skip unavailable metadata, support empty albums, and retain compilation/type information. |
| P2 | Parent-album download destinations were attached to the wrong track in optimized downloads. | Index destinations by the current track and sort using its album. A two-track regression test checks association. |
| P2 | Small configured inter-download waits were ignored. Temporary config changes could pass `None` as a type. Quoted FFmpeg arguments were split incorrectly. | Honor all positive delays, infer config types correctly, restore temporary values, and parse shell-style argument quoting. |
| P2 | Invalid settings were accepted until much later; config updates required login. | Validate booleans, finite numeric limits, codecs, regex, and FFmpeg arguments before writes/login. Standalone config updates exit offline. Add read-only `--doctor`. |
| P2 | Playlist common-directory calculation mutated its input and chose the wrong directory for matching filenames in different folders. Finishing the last progress bar indexed an empty list. | Calculate the common parent without mutation; remove the completed bar by identity. |
| P2 | Docker referenced a nonexistent requirements file. Installs followed a moving librespot branch; build requirements did not match the package metadata. | Install from `pyproject.toml`, pin the verified librespot commit, declare directly imported dependencies, and require setuptools 77+ for the existing license fields. |

## Personalization and maintenance

- `profiles/corey.json`: album-artist folders, disc/track numbering, shared artist/album folders for playlist tracks, relative M3U8 exports, cover art, lyrics, source audio, and explicit retry/wait defaults. Select it with `-c`; existing defaults remain untouched.
- README and installation commands point to `afterglow-labs/Spotified` and include local setup, diagnostics, and test commands.
- A GitHub Actions workflow runs tests, focused Pylint checks, and package builds on Python 3.10–3.13. The obsolete upstream mirror workflow has been removed.
- Development dependencies and package discovery are explicit. Credential filenames are excluded from Git and Docker build context.

## Rename and quality improvements

- Renamed the Python package, CLI entry points, configuration directory, Docker service, local checkout, and GitHub repository to Spotified. Installed client remains Spotified by Afterglow Labs. Original copyright and upstream attribution are retained.
- Renamed the personal music and podcast directories and updated configured paths and archive references. Moved all seven existing tracks plus artwork and lyrics into artist/album folders: 21 files retained identical SHA-256 hashes. The M3U8 under `Playlists` resolves all seven entries, and live media-range and artwork requests succeed for every track. Original playlist/archive text and the move/hash manifest are backed up under ignored `.spotified/migrations/`. New playlist tracks use the same shared artist/album library.
- Added source and encoding quality controls to Settings and Downloads. Every conversion format defaults to its best preset, while the default Original format copies encoded audio. Queue jobs snapshot the selected options.
- Source fallback now prefers the highest available supported quality within the account limit. Opus bitrate is bounded for mono streams; encoder presets preserve channels and do not add normalization. FFmpeg conversion tests cover mono/stereo MP3, AAC and Opus, plus Vorbis and packet-preserving copy.
- Corrected package license metadata to Zlib to match the inherited license notice.

## Validation

### WSL2 server and iOS remote control

- Deployed the full server to `/home/corey/projects/Spotified` on Nibiru, exposed through private Tailscale HTTPS on port 8443. The Docker container is healthy. Existing HTTPS services on 443 and 8787 and the Mac client connection remain intact.
- The Linux AMD64 image passed **121 Python tests**. Authenticated HTTPS, secure cookies, saved Spotify connection, library indexing, artwork, and media range requests were verified. The initial library copy contains **217 checksum-verified files** and indexes 60 tracks and one playlist. Music is stored in `/home/corey/Music/Spotified Music` using artist/album folders.
- Jobs retain their source links, and eligible canceled/interrupted jobs can be restarted on the server. Imported active history is marked interrupted and does not start automatically.
- Replaced the initial web-view client with **native SwiftUI screens in 0.2.0 (2)**, following the connection/account, navigation, and visual patterns in `afterglow-labs/odysseus-ios` on `main`. The native client calls the authenticated API directly for library, jobs, and settings; audio download/storage remains on WSL. That release fetched artwork for display and had no audio-file save or playback code. Native streaming is added in 0.4.0 below.
- The final iPhone run passed **nine unit/API tests and two native UI tests**. Tests cover Keychain/origin boundaries, authenticated queue payloads, CSRF, explicit zero/false settings changes, failed mutations without automatic retries, expired sessions, and media/external URL rejection. The live WSL UI test covers login and all main screens and asserts zero web views. A loopback fixture verifies submit, cancel, restart, and settings-save receipts without contacting Spotify. Results: `ios/.build/Native-WSL-QA-3.xcresult`.
- The native WSL navigation flow also passed on an iPad simulator (`ios/.build/Native-iPad-QA-1.xcresult`). iPhone and iPad screenshots are retained in `docs/qa/ios-native-*.png`. The server queue and production settings were not changed by UI testing.
- Signed **0.2.0 (2)** with the existing Afterglow Labs ad hoc profile including the registered iPhone 16 Pro. Verified bundle/version, code signature, absence of embedded passwords/test bundles/web-view symbols, and IPA SHA-256. Delivered `Spotified-0.2.0-2.ipa` to that iPhone through Tailscale Taildrop and placed a copy on the Mac Desktop. Taildrop confirmed transfer; physical-phone installation still requires the user's Feather workflow because Xcode reports the phone unavailable. The private hosted IPA was also updated.
- Docker starts within WSL and the container restarts unless stopped. Windows boot-to-WSL startup and fresh remote Spotify OAuth callback routing remain unverified.

### Source links and restart deployment follow-up

- Found that the Mac runtime still contained the older frontend and a server module without `JobManager.restart`; WSL already had the feature. The Mac image `spotified:download-history-ready` updates only the web module and static UI on top of the current pacing-fixed image. Its 18 web/server tests pass. An offline browser flow verified visible saved links, cancellation, restart, and duplicate-restart prevention.
- Applied the tested image to the Mac service on November 13, 2026 after approval to interrupt and resume the active download. The updater preserved history/settings in `.spotified/download-history-update/backup-20261113-175219` and requeued the one active job. Live API verification confirmed the replacement is running, retains the original source and audio choices, and has `SKIP_EXISTING=True`; configuration is unchanged. The served frontend now includes source links and Restart, and the running server exposes `JobManager.restart`. The previous image remains available as `spotified:before-download-history`. This verifies restart and queue behavior, not completion of the audio download.
- iOS 0.2.1 (3) moves source links, Copy link, and Restart directly onto each download card, retains them in details, and disables restart when a retry is already active. Explicit link/button hit areas prevent Copy or View details from opening a source URL. Validation and delivery are recorded in `ios/README.md`.

### Native Spotify connection management

- iOS **0.3.0 (4)** adds **Settings → Manage Spotify connection**, with sign-in/account switching, a fresh saved-login check, current/last connection results, and pending-login cancellation. Spotify authorization uses a system browser sheet and a loopback receiver on the phone. The authenticated API relays the callback to the WSL worker; the PKCE verifier and token exchange stay on the server.
- Authorization validates the exact callback destination and random state, rejects repeat/expired/cancelled callbacks, and does not persist authorization URLs or codes in history. Login failures before authentication now update the account status instead of leaving a stale connected indicator. Existing saved credentials remain until a new login succeeds.
- The WSL replacement image passed **131 Python tests** and is deployed. Rollback images: `spotified:before-native-login` and `spotified:before-accesspoint-failover`; latest private backup: `.spotified/native-login-update/backup-20261114-031629` on WSL. Local validation passed **130 tests with one existing host encoder skip**. The Mac service retains its desktop login flow.
- A live authorization test reproduced the intermittent `Connection refused` error during the final saved-login check. WSL probes confirmed that Spotify's advertised `ap-gew4.spotify.com:80` refused connections, while the other advertised endpoints connected. Added bounded, paced transport failover for the pinned librespot library, socket connection timeouts, and tests for refused connections, duplicate endpoint prevention, exhausted attempts, and socket timeout restoration.
- The iOS archive/export and signature verification passed. Twelve unit/API tests, existing queue/settings and WSL navigation flows, and the new management fixture flow passed. A live WSL authorization round trip verified the phone callback relay, declined authorization, and a subsequent successful saved-login check. Fresh authorization still requires the user to complete Spotify's form; physical installation and successful new-account authorization are not claimed.
- `Spotified-0.3.0-4.ipa` was delivered to the iPhone through Taildrop on November 14. The private hosted IPA was updated and its SHA-256 verified. A copy is on the Mac Desktop.

### Request pacing correction

- Kept the current pinned librespot dependency; ported the linked fork's pacing approach instead of importing its unrelated changes or obsolete dependency branch.
- Full local suite: **120 passed, one host Vorbis encoder skip**. The pacing-only Linux ARM64 image passed **68 focused tests** for HTTP, actual pinned audio-key retry behavior, stream recovery, configuration, and cancellation. Repository-configured focused Pylint checks pass; a broader E/F lint pass still reports existing dynamic protobuf and model-typing warnings.
- Applied only five pacing-related Python files to the previously running Mac image, retaining the previous image for rollback. Changed only request-pacing values in the live configuration. Verified authenticated health/state, saved Spotify connection, deployed source hashes, and effective waits of 2 seconds per download request, 30 seconds per track, and 30/60/120 seconds per retry. No live audio download was used to validate this correction, so service acceptance remains unproven.


### Spotified app

- Native AppKit/WKWebView client built and installed as `/Applications/Spotified.app`; an actual window inspection confirmed the sidebar, library, download queue, settings, and absence of a browser address bar. The login is read from macOS Keychain. A cold launch with Docker stopped automatically started the service and reopened the authenticated library.
- Server uses a salted PBKDF2-SHA256 password hash, rate-limited sign-in, HttpOnly SameSite cookies, CSRF validation, trusted hosts/origins, and filesystem containment checks. Tests cover wrong credentials, cross-origin writes, unauthorized media requests, symlink traversal, and byte ranges.
- **105 Python tests passed** inside the Linux ARM64 Docker image after the quality and rename changes. Locally, **104 passed and one Vorbis encoder test was skipped** because this Mac’s FFmpeg build does not include that encoder. Focused Pylint and whitespace checks pass.
- Isolated Playwright tests passed for login/errors, album/playlist browsing, audio playback and seeking, persistent settings, input validation, queue cancellation, and mobile overflow. Test media and credentials are temporary and separate from personal data.
- Live Docker server accepted the configured account and verified saved Spotify credentials. A metadata-only preview returned a real track title and completed as `previewed`; audio was not downloaded.
- Local server interface and native client are verified. Remote-host deployment is covered above. Live audio downloads, developer API library access, and fresh reconnect-OAuth through the new button still require end-to-end verification.

### Earlier downloader review

- Python 3.11: **82 tests passed**, including the real FFmpeg/FFprobe integration test.
- Python 3.12: installed the built wheel into a separate environment and ran the regression suite and offline doctor from outside the checkout. The imported code came from that environment's `site-packages`.
- Built `dist/spotified-0.22.1-py3-none-any.whl` and `dist/spotified-0.22.1.tar.gz`.
- Focused Pylint checks for syntax errors, undefined variables, and use before assignment pass. `git diff --check` passes.
- Full `pylint --errors-only` still reports inherited diagnostics around dynamic metadata attributes, generated protobuf modules, optional fields, and search display control flow. This review does not claim a clean full lint run.
- Docker validated on Linux ARM64 through Colima: built `spotified:local`, passed `--doctor` and `--version`, and ran all **82 tests successfully inside the container**, including real FFmpeg conversion. The engine also passed the `hello-world` smoke test. CI is configured but has not run remotely.
- Live Spotify OAuth login succeeded in the Docker container, reusable credentials were saved, and Spotified reached its interactive mode menu. The subsequent Spotified metadata preview is described above. Python 3.12 emits a deprecation warning from the existing protobuf 3.20.1 dependency; changing that dependency needs compatibility testing with librespot's generated messages.

## Remaining work worth considering

1. An authenticated media-download pass for your developer client ID, a track, an album, a mixed playlist, and a podcast. Base Spotify OAuth and a single-track metadata preview are verified.
2. Separate typed configuration and session objects from module/class globals. Several content classes capture settings at import time, which limits embedding and switching profiles within one process.
3. More detailed per-item outcomes in the legacy CLI. The app now isolates each job and records completed/partial/failed outcomes, but the original CLI still has paths that print a failure and continue. The WSL app can restart eligible interrupted jobs from their saved links.
4. Archive indexing and coordinated writes for large libraries or simultaneous Spotified processes. The current text archives still require repeated scans and do not provide cross-process locking.

Implementation references: [Requests error handling](https://requests.readthedocs.io/en/latest/user/quickstart/#errors-and-exceptions) and [setuptools pyproject/license support](https://setuptools.pypa.io/en/latest/userguide/pyproject_config.html).

## Native streaming and artist library — 0.4.0 (5)

- Artists now open their albums, then songs. Album-artist tags keep featured performers in the correct collection. Album sorting supports name, release year, and recent additions; songs use disc/track order, while playlists preserve their original order and duplicates.
- Added native AVPlayer streaming, album/playlist queues, shuffle, seek, next/previous, mini-player, Now Playing, AirPlay, background audio, and system media controls. Server download jobs and original music files stay on WSL.
- The authenticated playback endpoint serves compatible files directly, prepares Ogg/Opus as temporary AAC 320 kbps HLS, and preserves FLAC samples in a temporary lossless ALAC stream. Playback streams require the server session cookie. Authentication, CSRF, library boundaries, range serving, source preservation, cache cleanup, and lossless samples are tested.
- The cache is bounded to 512 MiB, two simultaneous encoders, 256 MiB per conversion, and a three-minute conversion deadline. Old idle entries are evicted; shutdown removes temporary playback files. Long files that exceed these limits report a playback error; permanent originals are unchanged.
- WSL candidate: **135 Python tests passed**. Native: **15 unit/API tests**, artist/album/sorting/background playback, and four regression/real-WSL playback UI flows passed. The signed 0.4.0 (5) IPA is prepared; live activation waits for the active download to finish or permission to restart and resume it. Physical iPhone installation and playback remain unobserved.

## Spotify browsing and Afterglow appearance — 0.5.0 (7)

- Added Spotify account browsing and search to the web and native clients using the existing saved account. Playlists, liked songs, saved albums, and followed artists can be browsed and paged; selected songs or collections are queued for local server downloads. Reads and imports use authenticated API routes with bounded caching, request timeouts, CSRF validation, and whole-selection validation. See [protocol details](docs/SPOTIFY-CATALOG.md).
- Read-only live checks verified every collection and search category, including 75 playlists, 1,497 liked songs, 19 saved albums, and 15 followed artists. Desktop/mobile browser checks and the iPhone catalog UI flow verified browsing, pagination, selection, and queue requests against an isolated server with downloads disabled. The downloader's metadata preview resolved a real track.
- **148 Python tests passed**; the final defensive catalog-response change passed 34 focused catalog/server tests. The production frontend build, focused Pylint checks, and wheel/source-package builds passed. Existing jobs with missing titles are normalized so older native clients can still decode server state.
- Afterglow is the default iOS appearance. The retired Dark preference migrates to Afterglow; an explicit Light preference is retained. The iOS and Mac assets share a new purple, orange, and ivory music icon; [artwork provenance and prompt](docs/branding.md) are recorded.
- **19 native unit/API tests passed**, including the appearance migration. The native navigation UI flow passed with the new appearance against an isolated loopback fixture. Screenshots: [Afterglow login](docs/qa/ios-afterglow-login.png) and [account appearance](docs/qa/ios-afterglow-account.png).
- Signed **Spotified-0.5.0-7.ipa** was archived and exported on the Mac. Bundle version, archive signature, ZIP integrity, and packaged icon were verified. The server update remains staged while an existing download runs; installing the phone app and activating the matching server are separate steps. Physical-device installation has not been observed.
