# Spotified for Android

The Android app opens the server's mobile library, playlists, Spotify search, and download queue in Android System WebView. Selecting a song plays the original media URL, including Ogg Vorbis. The app uses the Spotified icon and supports Android 8.0 and later.

Connect Tailscale to reach Nibiru, open Spotified, and sign in with your server account. Use **More options → Music server** to change the address. HTTPS servers and HTTP on localhost are supported.

## Build

Install Android SDK Platform 36 and JDK 17 or later. From this directory, run `./gradlew assembleDebug` for a development APK or `./gradlew assembleRelease` for an unsigned release APK. The output is under `app/build/outputs/apk`. Sign release builds with Android SDK `apksigner` and the same private Spotified release key for in-place updates.
