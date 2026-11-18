# Spotified design and verification

The user requested the way Odysseus functions and looks: a standalone app window, saved credentials, and a server connection. The active reference is [spotified-concept.png](spotified-concept.png), generated after the user named the app **Spotified, by Afterglow Labs**.

## Design system

The live Odysseus checkout supplied the dark palette and Fira Code typography: canvas `#282c34`, sidebar `#111111`, text `#9cdef2`, coral accent `#e06c75`, borders `#355a66`. The background is solid dark charcoal, without a gradient or image overlay. Fira Code regular and semibold files are self-hosted with their OFL license. Controls are 13–14px, the page title 28px, the empty-state title 22px, sidebar 224px. Mobile uses a 62px icon rail and wrapping form controls.

Allowed primary-screen copy: Spotified; by Afterglow Labs; Library; Albums; Artists; Playlists; Downloads; Settings; Your music, organized.; Add music; Search your library; Refresh; Your collection starts here; Add a Spotify album, playlist, or track.; Artists, albums, and artwork will appear here.; This Mac · Docker; Spotify connected; 0 tracks. Connection state and track counts are real data. A native OS titlebar supplies the window controls, not simulated browser chrome.

React components separate the app shell, library, downloads, settings, and API calls. The library uses real metadata, cover files or embedded artwork, M3U8 entries, and audio playback. The queue and settings extend the same flat, separated-row visual system because the user explicitly requested those functions. No fake albums, statistics, or media are shown in the personal library. The native icon is a separate Image Gen asset at `macos/Spotified.png`; it is packaged as `Spotified.icns`.

## Evidence and method

- Native AppKit/WKWebView window inspected through CUA at 1200px logical width. Confirmed its own titlebar, no URL bar, library navigation, settings, and live Spotify metadata preview.
- Cold start tested with the Docker service stopped: opening `/Applications/Spotified.app` started the service, authenticated with Keychain credentials, and displayed the connected library.
- Browser/IAB discovery returned “The browser access host is unavailable.” The frontend skill's fallback was an isolated headless Chrome driven by Playwright. It did not attach to the user's browser profile.
- Concept dimensions are 1487×1058 including the simulated native titlebar. Desktop content was captured at 1240×844 CSS pixels with a 1.2 pixel ratio, producing 1488×1013; the 45px difference is the native titlebar omitted by browser screenshots. The actual native titlebar was inspected separately.
- Mobile checked at 390×844. Fresh mobile contexts avoid a Chrome fractional-scale screenshot compositor artifact observed after resizing a desktop context. DOM width and screenshots are checked for overflow.
- `view_image` inspection compared the concept and final desktop/mobile captures in the same QA pass. Screenshots: [desktop library](qa/library-desktop.png), [mobile library](qa/library-empty-mobile.png), [mobile request pacing](qa/pacing-mobile.png). Test-only library screenshots use temporary fixture media, not personal downloads.

## Fidelity ledger

| Comparison | Evidence and resolution |
| --- | --- |
| Copy and navigation | Same six navigation entries, brand attribution, empty-state wording, search, refresh, and Add music actions. No unapproved above-the-fold copy added. Native window subtitle identifies the actual local host. |
| Layout and hierarchy | Black sidebar, charcoal canvas, upper heading/action row, separated search toolbar, centered record/empty state, bottom connection state and track count match the reference structure. |
| Typography | Actual Fira Code regular and semibold are loaded. A first render's missing semibold face was fixed; heading and button weights were re-inspected. Controls use an explicit compact desktop scale. |
| Palette and surfaces | Original Odysseus colors preserved; no warmed background, invented gradient, decorative cards, or marketing hero. Flat solid backgrounds intentionally omit image-generator texture. |
| Icons and artwork | Consistent outline navigation icons; the generic first record glyph was replaced with a custom thin-line grooved record matching the reference. Album art comes from actual files/tags. |
| Spacing and containers | Open empty state and fine separators preserved. Compact control spacing fits the 1200px native window. The OS supplies its own titlebar geometry and color. |
| Responsive behavior | Sidebar becomes an accessible icon rail, settings form stacks, search/refresh stay available, and no horizontal overflow occurs at 390px. Long hints and paths wrap. |

Above-the-fold copy diff: all concept labels retained on desktop; mobile intentionally abbreviates the sidebar wordmark to S and visually hides navigation labels while preserving accessible names. The implementation was visually verified against the active design. Remaining intentional differences are compact native-control sizing, OS-managed titlebar treatment, and the generated concept's texture being rendered as solid source colors. No material unresolved layout or functionality mismatch remains in the verified states.

## Functional verification

- 105 Python tests pass in the built Linux ARM64 Docker image. Locally, 104 pass and one Vorbis encoder test is skipped because the host FFmpeg omits that encoder.
- Focused Pylint checks and `git diff --check` pass.
- Playwright covers wrong/correct sign-in, actual tagged-file indexing, album and playlist browsing, playback, pause/seek, persistent settings, source/encoding quality defaults and overrides, invalid-link handling, preview queue/cancel behavior, and mobile overflow.
- A real Spotify metadata-only preview completed and returned a track title. No live audio download was performed.
- Remote deployment and a fresh Spotify OAuth flow through the new Reconnect button remain unverified end to end. The already saved Spotify session was verified repeatedly.

The installed app was re-opened after the complete Spotified rename. Native inspection confirmed the renamed music/podcast paths, artist/album layout for playlist tracks, Auto source quality, and Best encoding quality. The current seven-track library, artwork, and playlist references survive the folder migration; audio and sidecar files are byte-identical.
