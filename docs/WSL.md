# Nibiru WSL2 server

Server: `https://nibiru-darklight-1.osiris-cosmological.ts.net:8443`

The Linux host is reached over Tailscale with `ssh -p 2222 corey@nibiru-darklight-1`. Its project is `/home/corey/projects/Spotified`. The Mac client and Mac server retain their existing local connection.

The server uses Docker Compose, the existing server-account password hash, and saved Spotify credentials. It binds HTTP and the Spotify OAuth callback to WSL loopback. Tailscale Serve adds HTTPS port 8443 without changing the existing Odysseus service on 443 or Scopeweaver on 8787. It is accessible only within the tailnet.

```sh
cd /home/corey/projects/Spotified
DOCKER_CONFIG="$PWD/.spotified/docker-client" docker compose \
  --env-file .spotified/wsl.env -f compose.wsl.yaml up -d --build
sudo tailscale serve --bg --https=8443 http://127.0.0.1:8088
```

The isolated Docker client configuration avoids the unavailable Windows credential helper and leaves the host's other Docker configuration intact. The private `.spotified/wsl.env` defines the HTTPS origin and UID/GID. Private configuration and credentials remain in `.spotified/docker`, outside Git and Docker build context.

## Storage and pacing

- Music: `/home/corey/Music/Spotified Music`, mounted as `/music`.
- Podcasts: `/home/corey/Music/Spotified Podcasts`, mounted as `/podcasts`.
- Music uses artist/album folders. Playlists reference the shared library.
- The initial library transfer verified 217 files and 641,340,698 bytes by SHA-256; all playlist targets resolved. This is a copy, not a continuous sync with the Mac.
- Request delay: 2 seconds. Track delay: 30 seconds. Three retries with 30/60/120-second backoff. A longer server Retry-After takes priority.
- Imported history was marked interrupted where it was active on the Mac; no copied job starts automatically. Restart uses its saved source links and current server settings.

Docker is enabled in WSL and the container uses `restart: unless-stopped`. Tailscale Serve runs in the background. Windows boot-to-WSL startup has not been configured or tested; the server requires WSL to be running.

The Linux AMD64 image passed all 121 Python tests. Authenticated HTTPS, secure session cookies, saved Spotify login, library indexing, and copied media were verified. Audio download recovery after rate limiting is not established by these checks.

## Reconnecting Spotify from iPhone

With iOS client **0.3.0 (4)**, open **Settings → Manage Spotify connection → Sign in / switch Spotify account**. The system sign-in sheet returns Spotify's loopback callback to the phone, which relays it to WSL through the authenticated API. No SSH tunnel or exposed callback port is required. The PKCE verifier, token exchange, and saved Spotify credentials stay on WSL. You can also check the saved connection or cancel a pending sign-in from that screen.

The November 14 update is deployed on WSL. It passed all **131 Python tests** in the replacement Linux image. Previous images: `spotified:before-native-login` and `spotified:before-accesspoint-failover`; latest private settings/history/credential backup: `.spotified/native-login-update/backup-20261114-031629`. The Mac container retains its existing desktop sign-in flow.

The intermittent `Connection refused` failure was reproduced against one of Spotify's advertised access points (`ap-gew4.spotify.com:80`), while the other advertised endpoints connected. The server now tries other advertised endpoints after a connection failure, with bounded attempts, connection timeouts, and the configured request pacing. Authentication errors do not trigger this network failover.

## iPhone client

The signed app is distributed privately under `/ios/` on the same HTTPS port. The installer directory is `.spotified/ios-release`; it contains only the IPA, OTA manifest, icon, and install page. It does not contain server passwords or Spotify credentials. Tailscale Serve maps `/ios/` to that directory while `/` remains the authenticated Spotified server.

```sh
sudo tailscale serve --bg --https=8443 --set-path=/ios \
  /home/corey/projects/Spotified/.spotified/ios-release
```

The [private install page](https://nibiru-darklight-1.osiris-cosmological.ts.net:8443/ios/), OTA manifest, IPA checksum, and icon were verified over HTTPS. Existing Serve handlers on 443 and 8787 remain intact; Funnel is not enabled.

The native SwiftUI client sends queue and settings commands directly to the WSL API. Audio download jobs and storage remain on the server; the phone fetches metadata and artwork for its native library screens. Version 0.4.0 also streams songs from the server using authenticated media URLs; Ogg/Opus playback uses a bounded temporary AAC/HLS cache without changing the original files. Version 0.2.0 replaces the initial web-view implementation. The hosted mobile stylesheet remains for compatibility with the initial 0.1.0 client; the native client does not use it. Signed IPA delivery now uses Tailscale Taildrop and the existing Feather installation workflow.

## Playback update prepared November 16

The `spotified:library-playback-ready` image is staged beside the live service and passes all 135 Python tests. An isolated candidate server on loopback port 18088, with the actual music mounted read-only, was used to verify authenticated playback from the iOS simulator. It neither contacts Spotify nor alters the running download queue.

The guarded installer is `.spotified/library-playback-update/apply.py`. It refuses to update while history contains queued/running jobs, backs up configuration/history/source, retains `spotified:before-library-playback` for rollback, recreates the service, and checks health. The current download must finish or be deliberately stopped and requeued before activation. The Mac service is unaffected.
