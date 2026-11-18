# Spotify account browser

The Spotify tab in the native client and web client reads the account already connected to the server. It supports owned/followed playlists, liked songs, saved albums, followed artists, and catalog search. Opening a playlist or album shows songs; opening an artist shows releases. Select whole collections or individual songs, review audio options, and add the selection to the existing serial download queue. Downloads are stored on the server. This does not change the Spotify library.

## Server protocol

Authenticated `GET /api/spotify` accepts `view=playlists|liked|albums|artists|search|contents`, `offset`, optional `q` and `kind` for search, and a Spotify URI for contents. Pages contain normalized items, total, offset, and nullable next_offset. A page contains at most 20 source rows. Missing/deleted items cannot be selected. Pagination follows the source row count so missing items do not shift offsets.

Authenticated, CSRF-protected `POST /api/spotify/import` accepts `uris` (1 to 200 songs, albums, or playlists) and optional format, quality, bitrate. It validates the complete selection and available queue capacity before adding batches of at most 20 to the existing worker. It never starts playback or changes remote playlists.

The reader exchanges the existing stored credential with Login5, attaching the same client token to Login5 and subsequent Pathfinder requests. Tokens stay in server memory; credentials.json remains owned by the existing login/downloader flow. No developer API key, browser cookie, or new client-side Spotify secret is required. Tokens expire and refresh; replacement of credentials invalidates cached results. Reads have bounded network timeouts, serialized requests, a 64-page/60-second cache, and Retry-After handling. This adapter is separate from the audio worker.

Search and library queries use Pathfinder v2 persisted queries. Playlist contents and album/artist/track metadata use playlist v2 and extended-metadata. Persisted query changes are surfaced as a readable server-update error rather than a false empty library. Spotify may change these private protocols.

## Protocol references

- [spotatui search operations](https://github.com/LargeModGames/spotatui/blob/main/src/infra/spotify/search.rs)
- [librespot transport and Pathfinder](https://github.com/LargeModGames/spotatui-librespot/blob/spotatui/core/src/spclient.rs)
- [Login5 client-token pairing](https://github.com/LargeModGames/spotatui-librespot/blob/spotatui/core/src/login5.rs)
- [Library operation](https://github.com/NTifyApp/NTify-SpotAPI/blob/master/src/main/java/com/spotifyxp/spotapi/requests/library/GetLibrary.java)
- [Liked songs operation](https://github.com/NTifyApp/NTify-SpotAPI/blob/master/src/main/java/com/spotifyxp/spotapi/requests/library/GetLibraryTracks.java)

Read-only live checks on 2026-11-17 verified library pages, all four search types, playlist tracks, album tracks, and artist releases using the existing saved account. No account data or tokens are included in test fixtures. The prior null track-title response repair is included in this release so older native clients can still connect.
