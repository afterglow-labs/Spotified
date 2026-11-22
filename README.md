# Spotified, by Afterglow Labs

Personal music library and download app derived from the [original upstream project](https://github.com/Googolplexed0/zotify). A native macOS window connects to an authenticated Python server, with a Docker setup for this Mac. The original contributors retain credit. The Python package and both command-line entry points use the Spotified name. See [REVIEW.md](REVIEW.md) for the review findings, fixes, and validation limits.

## Mac app

Open **Spotified.app** from Applications. It has its own Dock icon and window, without a browser address bar. The app starts the configured local Docker server when needed. **Spotified → Connection Settings** changes the server or login; passwords are remembered in macOS Keychain. Spotify credentials remain in the server's private configuration directory.

- **Library, Albums, Artists, Playlists:** browse actual saved files, search tags, see artwork, play audio, and download files. M3U8 playlists reference the indexed library. Playback depends on the client's codec support; MP3 is an option for compatibility.
- **Spotify:** browse your connected account's playlists, liked songs, saved albums, and followed artists. Search the catalog, open collections, and select songs or whole albums/playlists to save on your server. This uses the existing Spotify login; no developer API key is needed. See [Spotify account browser](docs/SPOTIFY-CATALOG.md).
- Play a song to use Previous and Next in the current list. Delete a downloaded song, podcast episode, or album from the library after confirming. Deleting a local playlist keeps its audio files. These actions affect the selected Spotified server.
- **Downloads:** add Spotify links, preview metadata, queue downloads, cancel work, and inspect activity. Jobs run serially in isolated processes and retain history. Interrupted jobs are marked after restart and can be re-added.
- **Settings:** choose artist/album folders, separate or shared playlist storage, M3U8 exports, cover images, lyrics, output format, source and encoding quality, duplicate handling, and request pacing. Each queued job keeps the settings it was created with.
- Album artwork is embedded automatically when available. Separate cover images are optional. Existing files are never moved when changing a layout.

The current personal preset stores music in `~/Music/Spotified Music` and podcasts in `~/Music/Spotified Podcasts`. **Library** shows the server's downloaded media; **Spotify** browses your connected account and lets you choose what to save locally.

### iPhone client and WSL2 server

The WSL2 server runs at `https://nibiru-darklight-1.osiris-cosmological.ts.net:8443` within Tailscale. The native iPhone/iPad client controls downloads and streams the server library: download jobs run and files remain on that server. It follows the Odysseus iOS client with native SwiftUI navigation, Keychain login, and library/queue/settings screens that call the server API. Version 0.4.0 adds artist → album → song browsing, sorting, and native playback with an album/playlist queue, seeking, AirPlay, background audio, and lock-screen controls. The existing Mac client keeps its local connection.

See [iOS build and usage](ios/README.md) and [WSL deployment and storage](docs/WSL.md).

Version 0.5.0 adds the Spotify account browser and search to the native client. The web and desktop clients use Odysseus's Afterglow palette, static sunset glow, and system typography. The iOS app defaults to the matching native Afterglow appearance, with a purple and orange music icon. Existing Dark preferences migrate to Afterglow; Light remains available on iOS.

### Build and run

Requires the Python environment below, Node 22, Xcode command-line tools, Docker Compose, and Colima for automatic local engine startup.

```sh
cd frontend && npm ci && npm run build && cd ..
mkdir -p .spotified/docker
# For a NEW installation only; preserve an existing config and credentials.
cp -n profiles/corey.json .spotified/docker/config.json
.venv/bin/python -m spotified.web --config-dir .spotified/docker --set-password --username corey
docker compose build
./script/build_and_run.sh --verify
```

The build script installs `/Applications/Spotified.app` and rebuilds/restarts the Docker service when its image changes. Finish active downloads before rebuilding. The Codex **Run** action uses the same script. It is a local development build, ad-hoc signed, and its server launcher points to this checkout; rebuild after moving the repository. The client itself can connect to a remote server without a local Python runtime.

For a new Spotify session, choose **Settings → Reconnect Spotify**, then **Downloads → Continue to Spotify**. The local Docker setup exposes the OAuth callback on loopback port 4381. Existing saved Spotify credentials are reused.

In the native iOS app (0.3.0 or later), use **Settings → Manage Spotify connection → Sign in / switch Spotify account**. This authorizes the remote server from the phone; you can also check the saved connection and cancel a pending sign-in. See [the iOS client guide](ios/README.md).

### Server and credentials

Docker binds ports 8088 and 4381 to **127.0.0.1 only**. Private configuration, salted PBKDF2 password hashes, Spotify credentials, and queue history live in ignored `.spotified/docker/`; media is bind-mounted from the two music folders. No password is embedded in the app or repository. Closing the app leaves the server and downloads running. Stop the service with `docker compose stop`.

For a remote deployment, run `spotified-server --host 0.0.0.0 --config-dir /config --public-origin https://your-server.example` behind an HTTPS reverse proxy and configure the app with that origin and the server login. The native client requires HTTPS except on loopback. The WSL deployment uses `compose.wsl.yaml` and saved Spotify credentials; see `docs/WSL.md`. Fresh remote OAuth callback routing is separate from this checkout's local Compose file.

### Audio quality defaults

Settings and the download queue expose both source quality and encoding quality. The personal default is **Auto source quality + Original audio**. Auto targets the highest tier supported by this downloader for the account: 320 kbps for Premium, 160 kbps otherwise. When that tier is missing, the highest available supported tier is selected. This build does not download lossless source streams.

Every conversion format defaults to **Best quality for this format**:

| Format | Best preset |
|---|---|
| Original audio | Copy the original encoded audio without re-encoding. |
| MP3 | 320 kbps, maximum encoder effort. |
| AAC / M4A | 256 kbps per channel (512 kbps stereo), two-loop encoder. |
| Opus / Ogg | Up to 510 kbps stereo or 256 kbps mono, VBR, maximum complexity, audio mode. |
| Vorbis (CLI) | Quality 10. |

The presets preserve channel count and avoid normalization or forced resampling; Opus uses its supported sample rates. Encoding at a higher bitrate cannot restore missing source detail, and lossy conversion can discard information. Original audio is the closest match. The encoder options follow the [FFmpeg codec documentation](https://ffmpeg.org/ffmpeg-codecs.html). An explicit bitrate remains available for smaller files. Each queued job snapshots its quality settings.

Music, including playlist tracks, goes to `~/Music/Spotified Music/Artist/Album/Disc-Track - Title.ext`. Playlist exports live in `~/Music/Spotified Music/Playlists/` and reference that shared library. Podcasts go to `~/Music/Spotified Podcasts`. Docker mounts these same host folders; it does not store media inside the container.

### Request pacing

The personal preset waits **1 second between metadata/API operations** and **2 seconds between downloads**. It allows three retries with increasing delays of **5, 10, and 20 seconds**; HTTP `Retry-After` instructions can extend those waits. These are available in **Settings → Request pacing**. The settings pace application requests rather than every internal librespot network operation or audio chunk; they reduce request frequency without guaranteeing that rate limits cannot occur.

UI verification uses temporary audio, artwork, credentials, and library data, separate from personal files:

```sh
node frontend/qa.mjs </dev/null
```

The QA script launches an isolated headless Chrome. See [the design and verification notes](docs/web-design.md) for the Odysseus-derived styling and screenshots.

## Quick start for this checkout

```sh
uv venv --python 3.11
uv pip install -e '.[dev]'
.venv/bin/spotified --doctor -c profiles/corey.json
.venv/bin/spotified -c profiles/corey.json 'https://open.spotify.com/album/ALBUM_ID'
```

FFmpeg and FFprobe must be on PATH. On macOS, install them with `brew install ffmpeg`.
`--doctor` checks local configuration and executables without logging in, reading credentials, or creating files. An actual download opens the login flow when needed.

The [personal preset](profiles/corey.json) groups albums by album artist, names tracks `02-03 - Song.ogg` (disc and track), stores playlist tracks in the same artist/album library, exports relative M3U8 playlists and cover art, and places lyrics alongside songs. It uses source audio (`copy`), automatic quality, three retries, and a two-second pause between downloads. It is an editable starting point, selected with `-c`; it does not replace an existing default config.

Search, liked songs, and saved-library modes require your own developer client ID, configured as `API_CLIENT_ID` or supplied with `--client-id`. Account and API access depend on the service; the local doctor does not verify them.

```sh
.venv/bin/spotified -c profiles/corey.json --client-id YOUR_CLIENT_ID --liked
.venv/bin/spotified -c profiles/corey.json --client-id YOUR_CLIENT_ID --search 'Miles Davis /t album /s 20'
```

To keep private settings outside Git, copy the preset to an ignored local directory:

```sh
mkdir -p .spotified
cp profiles/corey.json .spotified/config.json
.venv/bin/spotified -c .spotified --update-config
```

Standalone `--update-config` fills in missing settings and exits without login. Command-line overrides apply to the current run and are not saved. Invalid boolean values, numeric limits, codecs, and regex patterns produce an error before login.

## Development checks

```sh
.venv/bin/python -m pytest -q
.venv/bin/python -m pylint spotified --disable=all --enable=syntax-error,undefined-variable,undefined-all-variable,used-before-assignment
.venv/bin/python -m build
```

Tests use temporary libraries and mocked network responses; they do not authenticate or download from the service. Integration tests use installed FFmpeg/FFprobe to convert generated mono and stereo audio, verify copy preserves encoded packets, and check that failed conversions preserve existing files. CI runs the tests on Python 3.10–3.13. The obsolete upstream mirror workflow has been removed.


## A highly customizable music and podcast downloader

<p align="center">
  <img src="macos/Spotified.png" width="160" alt="Spotified logo">
</p>

## Features

- Downloads at up to 320kbps \*
- Downloads directly from the source \*\*
- Downloads podcasts, playlists, liked songs, albums, artists, singles.
- Downloads synced lyrics from the source
- Option to download in real time to reduce suspicious API request behavior \*\*\*
- Supports multiple audio formats
- Download directly from URL or use built-in in search
- Bulk downloads from a list of URLs in a text file or parsed directly as arguments

\* Free accounts are limited to 160kbps \*\
\*\* Audio files are NOT substituted with ones from other sources (such as YouTube or Deezer) \*\*\
\*\*\* 'Real time' downloading limits at the speed of data transfer to typical streaming rates (download time ≈  duration of the track) \*\*\*

## Dependencies

- Python 3.10 or greater
- FFmpeg

## Installation And Updating

<details open><summary><strong>Install as Executable</strong></summary>

*Useable across system from the command line*

`pipx install git+https://github.com/afterglow-labs/Spotified.git`

</details>

<details><summary><strong>Install as Python Module</strong></summary>

*Useable when launched as a Python module*

`python -m pip install git+https://github.com/afterglow-labs/Spotified.git`

</details>

<details><summary><strong>Updating</strong></summary>

*Update in accordance with your install method*

**If Executable (pipx):**
`pipx install -f git+https://github.com/afterglow-labs/Spotified.git`

**If Module:**
`python -m pip install --force-reinstall git+https://github.com/afterglow-labs/Spotified.git`

</details>

### Advanced Installation Instructions

See [INSTALLATION](INSTALLATION.md) for a more detailed and opinionated installation walkthrough.

## Usage

`(python -m) spotified <track/album/playlist/episode/artist url>`

Download track(s), album(s), playlist(s), podcast episode(s), or artist(s) specified by the URL(s) passed as a command line argument(s).
If an artist's URL is given, all albums by the specified artist will be downloaded. Can take multiple URLs as multiple arguments.

### Basic Flags and Modes

`(python -m) spotified <{config flag} {config value}> <{mode flag}> <track/album/playlist/episode/artist url>`

| Command Line Config Flag (no value) | Function                                                                                                           |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `-h`, `--help`                      | See this message                                                                                                   |
| `-V`, `--version`                   | Show the version of Spotified                                                                                         |
| `-P`, `--persist`                   | Perform multiple Queries on the same Session, requiring only one account login                                     |
| `-T`, `--test`, `--dry-run`         | Perform a "dry run" of a Query, fetching metadata without downloading/modifying any music files                    |
| `--doctor`                         | Check local setup without login or file changes                                                                    |
| `--update-config`                   | Updates the `config.json` file while keeping all current settings unchanged                                        |
| `--update-archive`                  | Updates the global `.song_archive` file with full filepaths, keeping non-findable entries unchanged                |
| `--debug`                           | Enables debugging, printing extra information and creating a `config_DEBUG.json` file                              |

| Command Line Config Flag            | Value                                                                                                              |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `-c`, `--config-location`           | Specify a directory containing a Spotified `config.json` file (or a filepath to a `.json` file) to load settings      |
| `-u`, `--username`                  | Account username                                                                                                   |
| `--token`                           | Authentication token                                                                                               |

| Command Line Mode Flag (exclusive)  | Mode                                                                                                               |
|-------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `-s`, `--search`                    | Search tracks/albums/artists/playlists based on passed argument (interactive)                                      |
| `-p`, `--playlist`                  | Download playlist(s) created/saved by your account (interactive)                                                   |
| `-a`, `--artists`                   | Download all songs by followed artist(s) (interactive)                                                             |
| `-m`, `--albums`                    | Download followed albums (interactive)                                                                             |
| `-l`, `--liked`                     | Download all Liked Songs on your account                                                                           |
| `-f`, `--file`                      | Download all tracks/albums/episodes/playlists URLs within the file passed as argument                              |
| `-v`, `--verify-library`            | Update metadata for all Tracks in `ROOT_PATH` with an entry in the global `.song_archive` or directory `.song_ids` |

<details><summary>

### Advanced Usage and Config Flags

</summary>

All options can be set via the commandline or in a [config.json file](#configuration-files). Commandline arguments take priority over config.json arguments.  
Set arguments in the commandline like this: `-ie False` or `--codec mp3`. Wrap commandline arguments containing spaces or non-alphanumeric characters (weird symbols) with quotes like this: `--output-liked-songs "Liked Songs/{song_name}"`. Make sure to escape any backslashes (`\`) to prevent string-escape errors.

| Main Options                 | Command Line Config Flag            | Description                                                                  | Default Value             |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------|---------------------------|
| `ROOT_PATH`                  | `-rp`, `--root-path`                | Directory where music is saved (replaces `.` in other path configs)          | `~/Music/Spotified Music`    |
| `ROOT_PODCAST_PATH`          | `-rpp`, `--root-podcast-path`       | Directory where podcasts are saved                                           | `~/Music/Spotified Podcasts` |
| `SAVE_CREDENTIALS`           | `--save-credentials`                | Whether login credentials should be saved                                    | True                      |
| `CREDENTIALS_LOCATION`       | `--creds`, `--credentials-location` | Directory/Filepath to store/load a Spotified `credentials.json` file | See [Path Option Parser](#path-option-parser) |

| File Options                 | Command Line Config Flag            | Description                                                                  | Default Value             |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------|---------------------------|
| `OUTPUT`                     | `--output`                          | Master output file pattern (overwrites all others)    | See [Output Format Examples](#output-formatting) |
| `OUTPUT_SINGLE`              | `-os`, `--output-single`            | Output file pattern for single tracks             | See [Output Format Examples](#example-output-values) |
| `OUTPUT_ALBUM`               | `-oa`, `--output-album`             | Output file pattern for albums                    | See [Output Format Examples](#example-output-values) |
| `OUTPUT_PLAYLIST_EXT`        | `-oe`, `--output-ext-playlist`      | Output file pattern for playlists                 | See [Output Format Examples](#example-output-values) |
| `OUTPUT_LIKED_SONGS`         | `-ol`, `--output-liked-songs`       | Output file pattern for user's Liked Songs        | See [Output Format Examples](#example-output-values) |
| `SPLIT_ALBUM_DISCS`          | `--split-album-discs`               | Saves each disc of an album into its own subfolder                           | False                     |
| `MAX_FILENAME_LENGTH`        | `--max-filename-length`             | Maximum character length of filenames, truncated to fit, 0 meaning no limit  | 0                         |

| Download Options             | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `OPTIMIZED_DOWNLOADING`      | `--optimized-downloading`           | Whether to sort download order by item duration to reduce API ratelimiting               | True          |
| `DOWNLOAD_RATE_LIMITER`      | `-dlr`, `--download-rate-limiter`   | Slowdown multiplier based on the item's REAL_TIME_PLAY duration, 0 meaning disabled      | 0.0           |
| `BULK_WAIT_TIME`             | `--bulk-wait-time`                  | Wait time between track downloads, in seconds                                            | 30.0           |
| `TEMP_DOWNLOAD_DIR`          | `-td`, `--temp-download-dir`        | Directory where tracks are temporarily downloaded first, `""` meaning disabled           | `""`          |

| Album/Artist Options         | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `DOWNLOAD_PARENT_ALBUM`      | `--download-parent-album`           | Download a track's parent album, including itself (uses `OUTPUT_ALBUM` file pattern)     | False         |
| `NO_COMPILATION_ALBUMS`      | `--no-compilation-albums`           | Skip downloading an album if API metadata labels it a compilation (not recommended)      | False         |
| `NO_VARIOUS_ARTISTS`         | `--no-various-artists`              | Skip downloading an album if the album's artist is "`Various Artists`"                   | False         |
| `NO_ARTIST_APPEARS_ON`       | `--no-artist-appears-on`            | Skip album from an artist's discography if artist only "appears on" the album            | False         |
| `DISCOG_BY_ALBUM_ARTIST`     | `--discog-by-album-artist`          | Skip album from an artist's discography unless the artist is the album's artist          | False         |

| Regex Options                | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `REGEX_ENABLED`              | `--regex-enabled`                   | Enable Regular Expression filtering on item titles                                       | False         |
| `REGEX_TRACK_SKIP`           | `--regex-track-skip`                | Regex pattern for skipping tracks, `""` meaning disabled                                 | `""`          |
| `REGEX_ALBUM_SKIP`           | `--regex-album-skip`                | Regex pattern for skipping albums, `""` meaning disabled                                 | `""`          |

| Encoding Options             | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `DOWNLOAD_FORMAT`            | `--codec`, `--download-format`      | Audio codec, copy avoids remuxing (aac, fdk_aac, mp3, ogg, opus, vorbis)                 | copy          |
| `DOWNLOAD_QUALITY`           | `-q`, `--download-quality`          | Source audio quality, auto selects highest available (normal, high, very_high\*)         | auto          |
| `TRANSCODE_BITRATE`          | `-b`, `--bitrate`                   | Encoding preset: best, auto (source tier), or explicit bitrate such as 320k                 | best          |
| `CUSTOM_FFMEPG_ARGS`         | `--custom-ffmpeg-args`              | Additional FFMPEG functions or filters to apply to downloaded audio (space delimited)    |  `""`         |

| Archive Options              | Command Line Config Flag            | Description                                                                  | Default Value             |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------|---------------------------|
| `SONG_ARCHIVE_LOCATION`      | `--song-archive-location`           | Directory for storing a global .song_archive file        | See [Path Option Parser](#path-option-parser) |
| `DISABLE_SONG_ARCHIVE`       | `--disable-song-archive`            | Disable global .song_archive for `SKIP_PREVIOUSLY_DOWNLOADED` checks (NOT RECOMMENDED)  | False          |
| `DISABLE_DIRECTORY_ARCHIVES` | `--disable-directory-archives`      | Disable local .song_ids in download directories, use filenames to `SKIP_EXISTING`       | False          |
| `SKIP_EXISTING`              | `-ie`, `--skip-existing`            | Use local .song_ids file to skip songs already present in the expected output directory | True           |
| `SKIP_PREVIOUSLY_DOWNLOADED` | `-ip`, `--skip-prev-downloaded`     | Use the global .song_archive file to skip previously downloaded songs                   | False          |
| `SKIP_BY_ISRC`               | `-ii`, `--skip-by-isrc`             | Use International Standard Recording Codes to identify and skip (potential) duplicates  | False          |

| Playlist File Options        | Command Line Config Flag            | Description                                                                  | Default Value             |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------|---------------------------|
| `EXPORT_M3U8`                | `-e`, `--export-m3u8`               | Export tracks/albums/episodes/playlists with an accompanying .m3u8 file      | False                     |
| `M3U8_LOCATION`              | `--m3u8-location`                   | Directory where .m3u8 files are saved, `""` being the output directory       | `""`                      |
| `OUTPUT_M3U8`                | `-om`, `--output-m3u8`              | Output file pattern for Container .m3u8 files, `""` being the Query default  | `{name}`                  |
| `M3U8_REL_PATHS`             | `--m3u8-relative-paths`             | List .m3u8 track paths relative to the .m3u8 file's directory                | True                      |
| `LIKED_SONGS_ARCHIVE_M3U8`   | `--liked-songs-archive-m3u8`        | Use cumulative/archiving method when exporting .m3u8 file for Liked Songs    | True                      |

| Lyrics Options               | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `LYRICS_TO_METADATA`         | `--lyrics-to-metadata`              | Whether lyrics should be fetched and written to audio file tag metadata                  | True          |
| `LYRICS_TO_FILE`             | `--lyrics-to-file`                  | Whether lyrics should be fetched and written to a .lrc file                              | True          |
| `LYRICS_LOCATION`            | `--lyrics-location`                 | Directory where .lrc files are saved, `""` being the output directory                    | `""`          |
| `OUTPUT_LYRICS`              | `-oy`, `--output-lyrics`            | Output file pattern for .lrc files, `""` being the Track's output pattern  | See [Output Format Examples](#example-output-values) |
| `ALWAYS_CHECK_LYRICS`        | `--always-check-lyrics`             | Always download a song's lyrics, even when skipped (unless `OPTIMIZED_DOWNLOADING`)      | False         |
| `LYRICS_MD_HEADER`           | `--lyrics-md-header`                | Include track metadata to a .lrc file ([see tags here](https://en.wikipedia.org/wiki/LRC_(file_format)#Core_format)) at the start of a .lrc file | False                     |

| Metadata Options             | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `LANGUAGE`                   | `--language`                        | Language in which metadata/tags are requested                                            | en            |
| `MD_DISC_TRACK_TOTALS`       | `--md-disc-track-totals`            | Whether track totals and disc totals should be saved in metadata                         | True          |
| `MD_SAVE_GENRES`             | `--md-save-genres`                  | Whether genres should be saved in metadata                                               | True          |
| `MD_ALLGENRES`               | `--md-allgenres`                    | Save all relevant genres in metadata                                                     | False         |
| `MD_GENREDELIMITER`          | `--md-genredelimiter`               | Delimiter character to split genres in metadata, use `""` if array-like tags desired     | `", "`        |
| `MD_ARTISTDELIMITER`         | `--md-artistdelimiter`              | Delimiter character to split artists in metadata, use `""` if array-like tags desired    | `", "`        |
| `SEARCH_QUERY_SIZE`          | `--search-query-size`               | Number of items to fetch per category when performing a search                           | 10            |
| `STRICT_LIBRARY_VERIFY`      | `--strict-library-verify`           | Whether unreliable tags should be forced to match when verifying local library           | True          |
| `ALBUM_ART_TO_FILE`          | `--album-art-to-file`               | Save album art as a separate image file                                                   | False         |

| ZMD Options                  | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `IMPORT_ZMD`                 | `--zmd-import`                      | Whether to import ZMD files, using previously cached metadata                            | False         |
| `IMPORT_ZMD_LOCATION`        | `--zmd-import-location`             | Source for ZMD, either an individual .zmd file or a directory of .zmd files              | `./.zmd`      |
| `EXPORT_ZMD`                 | `--zmd-export`                      | Whether to export ZMD files, caching metadata for future use                             | False         |
| `EXPORT_ZMD_LOCATION`        | `--zmd-export-location`             | Destination for ZMD, updating an individual .zmd file or a directory of .zmd files       |`./.zmd`       |

| API Options                  | Command Line Config Flag            | Description                                                                   | Default Value            |
|------------------------------|-------------------------------------|-------------------------------------------------------------------------------|--------------------------|
| `API_CLIENT_ID`              | `--client-id`                       | Client ID for a Developer App to route metadata API requests through          | `""`                     |
| `API_CREDENTIALS_LOCATION`   | `--api-creds`, `--api-credentials-location` | Directory/Filepath to store/load a Spotified `api_credentials.json` file | See [Path Option Parser](#path-option-parser) |
| `API_CLIENT_LEGACY`          | `--client-legacy`                   | Whether the Developer App can access legacy endpoints\*\*                     | True                     |
| `FETCH_TIMEOUT`              | `--fetch-timeout`                   | Wait time for request callback before error, 0 meaning disabled               | 30.0                     |
| `FETCH_DELAY`                | `--fetch-delay`                     | Wait after download HTTP and audio-key requests, in seconds                   | 2.0                      |
| `RETRY_ATTEMPTS`             | `--retry-attempts`                  | Number of times to retry failed API requests                                  | 1                        |
| `RETRY_DELAY`                | `--retry-delay`                     | Initial wait between API retry attempts, in seconds                           | 30.0                      |
| `ESCALATING_DELAY`           | `--escalating-delay`                | Whether to double the `RETRY_DELAY` for each successive API failure           | True                     |
| `CHUNK_SIZE`                 | `--chunk-size`                      | Chunk size for downloading                                                    | 20000                    |
| `REDIRECT_TIMEOUT`           | `--redirect-timeout`                | Wait time for OAuth login request callback before error, 0 meaning disabled   | 120.0                    |
| `REDIRECT_ADDRESS`           | `--redirect-address`                | Local callback point for OAuth login requests                                 | 127.0.0.1                |
| `REDIRECT_PORT`              | `--redirect-port`                   | Destination port at `REDIRECT_ADDRESS` to receive OAuth login requests        | 4381                     |

| Terminal & Logging Options   | Command Line Config Flag            | Description                                                                              | Default Value |
|------------------------------|-------------------------------------|------------------------------------------------------------------------------------------|---------------|
| `PRINT_SPLASH`               | `--print-splash`                    | Show the Spotified logo at startup                                                          | False         |
| `PRINT_PROGRESS_INFO`        | `--print-progress-info`             | Show message contianing download progress information                                    | True          |
| `PRINT_SKIPS`                | `--print-skips`                     | Show message when a track is skipped                                                     | True          |
| `PRINT_DOWNLOADS`            | `--print-downloads`                 | Show message when a track is downloaded successfully                                     | True          |
| `PRINT_DOWNLOAD_PROGRESS`    | `--print-download-progress`         | Show track download progress bar                                                         | True          |
| `PRINT_URL_PROGRESS`         | `--print-url-progress`              | Show url progress bar                                                                    | True          |
| `PRINT_ALBUM_PROGRESS`       | `--print-album-progress`            | Show album progress bar                                                                  | True          |
| `PRINT_ARTIST_PROGRESS`      | `--print-artist-progress`           | Show artist progress bar                                                                 | True          |
| `PRINT_PLAYLIST_PROGRESS`    | `--print-playlist-progress`         | Show playlist progress bar                                                               | True          |
| `PRINT_WARNINGS`             | `--print-warnings`                  | Show warnings                                                                            | True          |
| `PRINT_ERRORS`               | `--print-errors`                    | Show errors                                                                              | True          |
| `PRINT_API_ERRORS`           | `--print-api-errors`                | Show API errors                                                                          | True          |
| `STANDARD_INTERFACE`         | `--standard-interface`              | Silence all non-mandatory prints and loaders, instead show a standardized dashboard      | False         |
| `FFMPEG_LOG_LEVEL`           | `--ffmpeg-log-level`                | FFMPEG's logged level of detail when completing a transcoded download                    | error         |

**\* very_high (320k) is limited to Premium accounts only**

**\*\* Developer Apps created before 2026-02 *may* be legacy**

</details>

## Configuration Files

Using the `-c` (`--config-location`) flag does not set an alternate config location permanently. Alternate config locations must be specified in the command line each time Spotified is run. When unspecified, the configuration file will be read from and saved to the following default locations based on your operating system:

| OS              | Location                                                           |
|-----------------|--------------------------------------------------------------------|
| Windows         | `C:\Users\<USERNAME>\AppData\Roaming\Spotified\config.json`           |
| MacOS           | `/Users/<USERNAME>/Library/Application Support/Spotified/config.json` |
| Linux           | `/home/<USERNAME>/.config/spotified/config.json`                      |

To log out, just remove the configuration file and credentials file. Uninstalling Spotified does ***not*** remove either.

## Path Option Parser

All pathing-related options (`CREDENTIALS_LOCATION`, `ROOT_PODCAST_PATH`, `TEMP_DOWNLOAD_DIR`, `SONG_ARCHIVE_LOCATION`, `M3U8_LOCATION`, `LYRICS_LOCATION`, `API_CREDENTIALS_LOCATION`) accept absolute paths.
They will substitute an initial `"."` with `ROOT_PATH` and properly expand both `"~"` & `"~user"` constructs.

The options `CREDENTIALS_LOCATION` and `SONG_ARCHIVE_LOCATION` use the following default locations depending on operating system:

| OS              | Location                                                |
|-----------------|---------------------------------------------------------|
| Windows         | `C:\Users\<USERNAME>\AppData\Roaming\Spotified\`           |
| MacOS           | `/Users/<USERNAME>/Library/Application Support/Spotified/` |
| Linux           | `/home/<USERNAME>/.local/share/spotified/`                 |

## Output Formatting

With the option `OUTPUT` (or the commandline parameter `--output`) you can specify the pattern for the file structure of downloaded tracks (not podcasts).
The value is relative to the `ROOT_PATH` directory and may contain the following placeholders (`ITEMTYPE` may be `track`, `album`, `artist`, or `playlist`):

| Placeholder                            | Description                                                  |
|----------------------------------------|--------------------------------------------------------------|
| `{id}`                                 | The downloaded track's id                                    |
| `{name}`                               | The downloaded track's name                                  |
| `{artist}` / `{artists}`               | The downloaded track's artist(s)                             |
| `{date}` / `{year}`                    | The downloaded track's release date/year                     |
| `{track_number}` / `{disc_number}`     | The downloaded track's track/disc number                     |
| `{eac}` / `{isrc}` / `{upc}`           | The downloaded track's EAC/ISRC/UPC code                     |
| `{album}`                              | The album's name                                             |
| `{album_artist}` / `{album_artists}`   | The album's artist(s)                                        |
| `{playlist}`                           | (playlist only) The playlist's name                          |
| `{playlist_num}`                       | (playlist only) Incrementing item number                     |
| `{ITEMTYPE_id}`                        | (only when item relevant) The specific item's id             |
| `{ITEMTYPE_name}`                      | (only when item relevant) The specific item's name           |

### Example Output Values

`OUTPUT_SINGLE`         :   `{artist}/{album}/{artist}_{song_name}`

`OUTPUT_ALBUM`          :   `{album_artist}/{album}/{album_num}_{artist}_{song_name}`

`OUTPUT_PLAYLIST_EXT`   :   `{playlist}/{playlist_num}_{artist}_{song_name}`

`OUTPUT_LIKED_SONGS`    :   `Liked Songs/{artist}_{song_name}`

`OUTPUT_LYRICS`         :   `{artist}_{song_name}`

## M3U8 File Output Formatting

With the option `OUTPUT_M3U8` (or the commandline parameter `--output-m3u8`) you can specify the pattern for the filename of Container playlist files. Unlike [Output Formatting](#output-formatting), this value cannot include subdirectories (no `/` or `\`) but may contain the following placeholders:

| Placeholder                            | Description                                                         |
|----------------------------------------|---------------------------------------------------------------------|
| `{content_type}`                       | The type of content the Container holds (`track`, `episode`, etc.)  |
| `{id}`                                 | The Container's id                                                  |
| `{name}`                               | The Container's name                                                |
| `{owner_id}`                           | (playlist only) The playlist owner's id                             |
| `{owner_name}`                         | (playlist only) The playlist owner's name                           |
| `{snapshot_id}`                        | (playlist only) The playlist's snapshot id                          |

## Search Query Formatting

Searches (performed with either with the mode flag `-s` or no mode flag) can be filtered with the following general format:

`<search term(s)> <{filter tag} {filter value}>`

Multiple filters can be stacked, with latter filters overwriting prior filters. **The `SEARCH_QUERY_SIZE` config will be overwritten by the `/limit` filter if it is set.**

### Supported Filters

| Filter Tag                  | Type       | Valid Values                                              | Default Value                    |
|-----------------------------|------------|-----------------------------------------------------------|----------------------------------|
| `/t`, `/type`               | `ITEMTYPE` | `track`, `album`, `artist`, `playlist`, `show`, `episode` | `track,album,artist,playlist`    |
| `/s`, `/size`               | int        | 1 <= i <= 1000                                            | `SEARCH_QUERY_SIZE` Config       |
| `/o`, `/offset`             | int        | 0 <= i <= 999                                             | 0                                |
| `/ie`, `/include-external`  | bool       | True, False                                               | False                            |

### Example Filtered Search Queries

Only Search for Playlists                    :   `Awesome Tunes /t playlist`

Search for Lots of Artists                   :   `Taylor /t artist /s 50`

Skip the First 100 Search Results            :   `LMFAO Party Rock /o 100`

Smaller Default Search, Including Podcasts   :   `Country /t track,album,artist,playlist,episode /s 5`

Search for Externally-Hosted Podcasts        :   `Life is Crazy Sometimes /t show /ie True /s 30`

## Regex Formatting

With `REGEX_ENABLED` (or the commandline parameter `--regex-enabled`) and its child config options, you can specify a Regex pattern for the titles of different items (tracks, albums, playlists, etc.) to be filtered against. To understand the Regex language and build/test your own, see [regex101](https://regex101.com/). Make sure to escape any backslashes `\` used in the Regex, as a `config.json` will not accept lone backslashes. **All Regex patterns/matches are case-insensitive**.

You can add multiple patterns into a single regex by chaining the "or" construction `|`, such as: `(:?<first pattern here>)|(:?<second pattern here>)|(:?<third pattern here>)`.

### Example Regex Values

Check for Live Performances   :   `^.*?\\(?(?:Live|Live (?:from|in|at) .*?)\\)?$`

## FFMPEG Argument Formatting

With `CUSTOM_FFMEPG_ARGS` (or the commandline parameter `--custom-ffmpeg-args`), you can specify additional audio processing functions to be applied to downloaded audio files. To understand available FFMPEG options and filtergraphs, see the [FFMPEG Documentation](https://ffmpeg.org/ffmpeg.html#Audio-Options) and [FFMPEG Filters Documentation](https://ffmpeg.org/ffmpeg-filters.html#Audio-Filters). Make sure to escape any extra quotes `"`, as the argument parser expects a single string of space-delimited key-value pairs.

### Example FFMPEG Argument Values

Increase Volume by 50%                                :   `"-af volume=1.5"`

Decrease Volume by 50% for the First 30 Seconds       :   `"-af volume=0.5:enable='between(t,0,30)'"`

Slow Audio Tempo to 60% (pitch/frequency unaffected)  :   `"-af atempo=0.6"`

Increase Volume and Tempo by 50%                      :   `"-af volume=1.5,atempo=1.5"`

## Docker Usage

### Build a Docker Image from the Dockerfile

`docker build -t spotified .`

### Create and Run a Container from the Docker Image

`docker run -it --rm -p 4381:4381 -v "$PWD/Spotified Music:/root/Music/Spotified Music" -v "$PWD/Spotified Podcasts:/root/Music/Spotified Podcasts" spotified`

## Podman Usage

`podman run -it --rm --name spotified --network=host -v "$PWD/Spotified Music:/root/Music/Spotified Music" -v "$PWD/Spotified Podcasts:/root/Music/Spotified Podcasts" spotified`

(Recommended Additional Configs: `--cap-drop=ALL --security-opt=no-new-privileges`)

## Common Questions

<details><summary>

### What do I do if I see "Your session has been terminated"?

</summary>

If you see this, don't worry! Just try logging back in. If you see the incorrect username or token error, delete your `credentials.json` and you should be able to log back in.

</details>

<details><summary>

### What do I do if I see repeated "Failed fetching audio key!" errors?

</summary>

The [bgeorgakas fork's workaround](https://github.com/bgeorgakas/zotify#readme) recommends a 30-second pause after each successful download and delayed retries. Spotified now defaults to `BULK_WAIT_TIME=30`, `FETCH_DELAY=2`, and `RETRY_DELAY=30`. The personal preset allows three retries with escalating waits of 30, 60, and 120 seconds. Download HTTP requests (including librespot metadata/CDN calls) and audio-key requests wait after each attempt, including failures. Librespot's immediate audio-key retry is disabled so these retries use Spotified's backoff. Exhausted stream retries also wait before moving to another track. HTTP 429 responses honor a longer `Retry-After`, including on the final attempt. Existing configuration files retain their saved values; check Settings → Request pacing.

These waits reduce request frequency; they cannot guarantee Spotify accepts a request. An audio-key rejection alone does not confirm rate limiting. Persistent rejections may require a longer break or investigation of another service/account error.

</details>

<details><summary>

### Will my account get banned if I use this tool?

</summary>

Only two users have ever reported an account getting suspended after using Spotified, and this only occurred after ***several days** of non-stop usage*.

Spotified is recommended for use with a burner account, in reasonable batches of content, for reasonable periods of time.

Ultimately, you use this program at your own risk.

</details>

## Disclaimer

Spotified is intended to be used in compliance with DMCA, Section 1201, for educational, private, and fair use.

Spotified contributors are not responsible for any misuse of this program or source code.

Spotified is not associated with any external entities, organizations, companies, or services.

## Contributing

Please refer to [CONTRIBUTING](CONTRIBUTING.md)
