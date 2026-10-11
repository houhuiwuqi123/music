# AURU MUSIC — SwiftUI iOS Player

A modern, local-first music player built with SwiftUI and AVFoundation for iOS 16 and later.

## Features

- Imports multiple audio and video files with SwiftUI's native `fileImporter`.
- Copies imported audio into the app's Documents/Imported Music directory.
- Recursively detects compatible files copied directly into the app's Documents directory.
- Reads title, artist, album, duration, and embedded artwork with `AVURLAsset`.
- Plays through `AVPlayer` with play/pause, seeking, previous/next, shuffle, list repeat, and repeat-one modes.
- Provides Home, Songs, Artists, and Playlists tabs with global search.
- Tracks recent plays when playback starts; increments song/video play counts only when AVPlayer reaches the end. Skipping, pausing, or switching media does not increment counts. Each completed repeat counts once.
- Supports persistent playlists; a song can belong to multiple playlists.
- Adds Candy广场 after Artists: an animated, searchable starfield of online listeners; automatically shares their current songs over WebRTC; shows approximate IP regions and keeps local receive histories.
- The mini-player and song-row playlist selector stays open for multiple selections. Tap an already selected playlist to remove the song; tap Done or dismiss the sheet to close it. Song details use the same membership toggle.
- Supports custom covers for songs and playlists through the native Files importer.
- Provides song details with metadata, playlist assignment, and permanent local deletion.
- Provides playlist details with cover upload and add/remove song management.
- Song rows provide an ellipsis menu for details, playlist assignment, play-next, rename, and permanent deletion.
- Deduplicates imported and discovered songs by normalized title, artist, album, and duration.
- Song deletion asks whether to hide the song from the library while keeping its sandbox file or permanently delete the app's local copy.
- Music and playlist rows support native full-swipe deletion with confirmation choices.
- Playlist rows support right-swipe deletion as well as the existing left swipe. Every playlist deletion entry offers only two actions (plus Cancel): delete the playlist while keeping music, or delete the playlist and its local audio files. Local-file deletion also clears the songs from the library, other playlists, and playback statistics. If a file cannot be deleted, the error is shown and the playlist is kept; any files already deleted remain deleted.
- Empty artist and playlist data no longer render empty glass cards.
- The app icon asset is configured at `AURU MUSIC/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
- Reads embedded lyrics and supports uploaded UTF-8 LRC/text lyrics with synchronized scrolling in Now Playing.
- Imports UTF-8 `.lrc` files as lyrics, never as audio/video. Batch selection associates lyrics with the same filename stem, regardless of selection order, including deduplicated songs and renamed local copies. Standalone LRC imports require an unambiguous matching song; missing/ambiguous matches are reported rather than assigned to an arbitrary song.
- Cleans deleted songs out of playlists and playback statistics automatically.
- Shows local videos in global search and on the matching artist page, then plays them with the system video player.
- Includes a floating mini player and full Now Playing screen in a dark glass design.
- Includes Chinese/English settings, notification permission, version, policy, and support views.
- Sends an optional local notification after media import completes.
- Uses the playback audio session and background audio mode.

## Run

1. Copy this folder to macOS with Xcode 15 or newer.
2. Open `MusicPlayer.xcodeproj`.
3. Select the **AURU MUSIC** target.
4. Under **Signing & Capabilities**, choose your Apple Developer Team and change the bundle identifier if needed.
5. Choose an iPhone simulator or connected iPhone and press **Run**.
6. Tap the import button and choose audio files from the Files picker.

The deployment target is iOS 16.0. The Xcode project resolves the WebRTC binary Swift Package when first opened/built. Candy广场 connects to `wss://music.webtrc.eu.cc/ws` and uses Google STUN for WebRTC. No insecure ATS exception is needed.

When updating a macOS copy, sync the complete project, including both Candy Plaza Swift files and `MusicPlayer.xcodeproj/project.pbxproj`. Both files are already registered in the AURU MUSIC target's Compile Sources phase. If Xcode reports `Cannot find 'CandyPlazaService' in scope`, check the earlier build errors in the service file and confirm these files and the project configuration were copied together.

WebRTC is a binary Swift Package dependency. Both app build configurations set Runpath Search Paths to `$(inherited)` and `@executable_path/Frameworks` so the executable can load the embedded framework at launch. If an older build crashes with `Library not loaded: @rpath/WebRTC.framework/WebRTC` and `no LC_RPATH's found`, sync the project configuration, use Product > Clean Build Folder, then build and install again. Verify the built app contains `Frameworks/WebRTC.framework/WebRTC` and that `otool -l` on the app executable lists an `LC_RPATH` with `@executable_path/Frameworks`. The shared Run scheme also enables `IDEPreferLogStreaming=YES` for Xcode launch diagnostics; this logging setting does not fix a missing framework.

## How local files are recognized

The app cannot read arbitrary files elsewhere on an iPhone because iOS apps run in a sandbox. Use either supported workflow:

1. **Native Files picker:** tap the import button in the app. SwiftUI `fileImporter` opens the system Files interface. Selected files from On My iPhone, iCloud Drive, Downloads, or an installed provider are accessed through security-scoped URLs, coordinated with the provider, copied into `Documents/Imported Music`, and indexed immediately.
2. **Finder or iTunes file sharing:** connect the iPhone to a Mac or PC, open its Files/File Sharing section, select **AURU MUSIC**, and copy audio files into the app. Reopen or foreground the app to scan Documents automatically.

The project enables both `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. The scanner accepts every file type declared by iOS as audio or movie. It also explicitly recognizes common audio extensions including MP3, AAC, M4A/M4B, WAV, AIFF, CAF, FLAC, AC3/EAC3, AMR, OGG/OGA, Opus and WMA, plus common video containers including MP4, MOV, M4V, MPEG, 3GP, AVI, MKV, WebM, MTS/M2TS and TS. FLAC is supported directly through AVFoundation on current iOS versions. Playback of any container still requires its internal codec to be supported by the installed iOS version.

For lyrics, select `Song.mp3` and `Song.lrc` together, or import `Song.lrc` after importing the matching song. Imported lyrics are stored next to the local audio copy and persisted in its library entry. During Documents scans, same-stem LRC files fill missing lyrics on both new and already indexed songs; a match in the same directory takes precedence. Embedded lyrics and manually edited/uploaded lyrics are preserved during scans. Unmatched sidecars are left untouched, so they can be picked up after their song is added. Import/scan error alerts show at most five file details plus the remaining failure count.

### Development and Simulator files

- In Simulator, first place media in a location visible to the simulated **Files** app, such as iCloud Drive or a provider exposed in Browse, then use the app's import button.
- On a development iPhone, choose files from **On My iPhone**, **Downloads**, iCloud Drive, or another enabled Files provider.
- Provider and iCloud files may be placeholders. The app uses `NSFileCoordinator` while its security-scoped permission is active, allowing the provider to download the selected file before it is copied.
- Direct access to arbitrary Mac folders or paths outside the iOS sandbox is intentionally unavailable. Files must be selected through `fileImporter` or copied through Finder file sharing.

## Structure

- `AURU MUSIC/Models/Track.swift` — persisted audio model and duration formatting.
- `Models/Playlist.swift` — playlist, artist grouping, and play-stat models.
- `Services/LocalMusicLibrary.swift` — document import, sandbox copying, metadata, persistence, and deletion.
- `Services/MusicDataStore.swift` — persistent playlists, recent history, and rankings.
- `Services/AppSettings.swift` — app language, notification preference, and localized labels.
- `Player/MusicPlayerViewModel.swift` — AVPlayer engine and playback state.
- `Views/RootView.swift` — global toolbar, search, tabs, native SwiftUI `fileImporter`, and floating player.
- `Views/FeatureViews.swift` — Home, Songs, Artists, Playlists, and detail screens.
- `Views/GlassComponents.swift` — reusable dark glass cards, rows, and backgrounds.
- `Views/MiniPlayerView.swift` — persistent bottom controls.
- `Views/NowPlayingView.swift` — artwork, seek slider, controls, and repeat mode.

## Notes

The repository is generated on Windows, where Xcode and the iOS SDK are unavailable. Build and signing must be performed on macOS. Add an AppIcon asset in Xcode before App Store distribution.

### Candy广场

The public-sharing switch lives in Settings, defaults to on and persists locally. The plaza profile button edits nickname (default "游客" plus a random number) and an optional avatar, resized to a 96-pixel JPEG up to 32 KB. Stars show only the avatar (or a star), nickname plus approximate IP region on the first line, and a single-line truncated song title on the second. Every meteor emerges in the bottom-right area, travels to the top-left, shrinks from 1.15 to 0.45 scale, then fades and repeats on a slightly different path over a 14-second cycle. Offline stars turn gray, freeze and disappear 60 seconds after detected disconnection. The supplied astronaut background (`PlazaEmpty`) appears when no other online listeners exist; the supplied lunar/starfield background (`PlazaOnline`) appears when at least one does. Paused online listeners retain their stars and the online background. Search filtering and gray offline stars do not select the background. Images fill the field without stretching, anchored bottom-right to retain the astronaut. Connection status is shown only in the upper-right capsule, without inline connection error text.

Playing a local song automatically makes that song downloadable; pausing retains it, switching songs replaces the share, and disabling publicity, switching to video or clearing the song withdraws it. Only share music you have permission to distribute. The manual publish UI is removed. Playback is observed at the root view, regardless of the selected tab. Client IDs are now persisted so reconnects restore the same star rather than creating duplicates.

The backend source lives in `backend/`; see [deployment instructions](backend/README.md). Deploy and restart the updated backend together with the App update. Listening messages include an optional file and base64 avatar; the server validates images, assigns ownership/region and sets `offlineAt` (Unix seconds). A 30-second heartbeat refreshes status. A detected disconnect or 90 seconds without a refresh immediately withdraws downloads and marks the star offline; a one-second cleanup removes it after 60 seconds. Opt-out/clearing the song removes it immediately. A stopped or suspended app cannot instantly detect every network loss.

Tapping an online star offers Download / Cancel only; downloading does not pause local playback. The reliable protocol requires both a version-2 publisher and the updated signaling service. Original files use an authorized `file-v2:<transferId>` reliable ordered WebRTC channel or a temporary HTTPS gateway, preserving receive history and the save/share flow. The old PCM/legacy transfer channels are not accepted by the new App; older clients may still view metadata but cannot receive reliability guarantees.

Automatic sharing hashes the original file asynchronously without copying/deleting it. On song changes, **new requests for the old publication stop, but existing authorized transfers keep their original manifest/source snapshot and may finish or resume**. Closing public sharing, clearing playback, source file deletion/mutation, or detected source disconnection revokes authorization. Downloads are saved under `Documents/Candy Downloads`; partial data is under `.partial`, not shown as completed music. No local file path or raw IP is broadcast. GeoIP remains a local MMDB lookup. Source iOS devices must remain available; the App does not misuse audio background modes to keep uploads alive.

Reliable transfers are implemented in `Services/CandyReliableTransfer.swift`: at most two receiving tasks, disk-actor streaming rather than whole-file memory, 256 KB durable checkpoints with prefix SHA-256, strict offsets and a 1 MB sender ACK window, bounded 2 MB incoming queues, SHA-256 validation before completion, and idempotent completion records. Network errors back off with jitter for up to five minutes; partials can be retried for 24 hours, or explicitly cleared. The plaza now shows task progress, waiting/recovery status, Cancel, Retry and Clear Partial controls. P2P senders are paced at 512 KB/s per task (maximum two); one relay upload shares a FIFO token budget with the P2P tasks, capped at 1 MB/s total with a 1 MB burst. These are bounded initial limits, not adaptive bandwidth estimates or unlimited throughput.

The server allocates two P2P slots per source; further requests can share a single verified temporary gateway upload, and failed P2P attempts can request relay fallback. HTTP uploads use Content-Range and durable Upload-Offset; downloads use bounded Range requests with an immutable SHA-256 ETag. Bearer URLs must use HTTPS on `music.webtrc.eu.cc` (proxy the gateway on this same hostname); redirects are rejected so tokens cannot escape to another host. Persistent client identity secrets are stored in the iOS Keychain. TURN credentials come from server configuration rather than being embedded in the App. See [backend deployment and limits](backend/README.md).

Code support is not a deployed service or a measured mobile-network SLA: the gateway needs public HTTPS, disk/bandwidth quotas and TURN needs its own reachable ports/certificate. Neither is a Cloudflare dependency. Source departure/privacy withdrawal invalidates cached download access; this remains online-only sharing, not offline collection. iOS suspension, source unavailability and exhausted server capacity still produce explicit waiting/failure states.

The initial server snapshot must arrive within 15 seconds before the UI reports online. Connection failures are retained internally for diagnostics and retried after 3 seconds; the plaza shows only the status capsule, not inline network errors. Old socket responses and cancelled retries cannot affect a newer connection. An empty snapshot may omit `files` and is treated as an empty plaza.

For public connectivity checks, do not rely on a local hosts entry for music.webtrc.eu.cc. Resolve public DNS and verify the TLS WebSocket upgrade returns HTTP 101 plus a `plaza` snapshot. Cloudflare HTTP 522 means the edge cannot reach the origin; the server operator must check the origin address, port/firewall and reverse-proxy WebSocket configuration. Changing the app alone cannot repair this server-side failure.

Run `node scripts/verify-candy-connection.cjs` for source/config regression checks, or add `--live` to also verify every public IPv4 address using validated TLS, HTTP 101 and the actual initial snapshot. The live check ignores the local hosts mapping, publishes no files, and returns a failing exit code for unavailable endpoints. These checks do not replace an Xcode build or iOS-device test.

On macOS run `node scripts/verify-candy-disk.cjs` to compile and execute the actual production disk actor (resume, corrupt prefix, wrong offset/hash, zero-length files, completion recovery and filename confinement). Run `node scripts/verify-candy-ios.cjs` for an unsigned iOS Simulator Xcode build. Windows source checks are not a substitute for either command. Do not report P2P/NAT/weak-network acceptance until the two-phone tests below have run.

### Regression checks on iOS

- Edit nickname/avatar in the plaza, then check a second phone shows only the avatar, nickname/region and truncated song title. Toggle publicity in Settings and restart to check persistence.
- Disconnect one phone: its star should turn gray and stop moving; reconnect within 60 seconds to restore the same star, or leave it offline for 60 seconds to verify removal. Check explicit opt-out removes it immediately. A silent network failure may take up to the heartbeat timeout to be detected.
- Tap a star: only Download / Cancel should appear and local playback must not pause. Download MP3/M4A/FLAC files (5/20/200 MB) and compare SHA-256 with originals; verify progress, history and save/share. Switch source songs mid-download: the authorized old transfer must finish, while new old-file requests fail. Explicit opt-out must stop all original and cached transfers.
- Disconnect the recipient network for 30 seconds, then change Wi-Fi/cellular: downloads must resume the persisted prefix instead of starting at zero. Source disconnect must revoke its cache/grants; after source reconnect and republication a new authorized request may reuse the same content checkpoint, not bypass authorization.
- Test 2/10/100 simultaneous recipients in an isolated gateway setup; only two P2P senders and one relay upload may run per source. Compare all resulting file hashes; test queue/capacity rejection, corrupt uploads, Range recovery, cancellation, low disk space and gateway/TURN failures. A single source upload must fan out to relay recipients. Test forced TURN on two networks separately.
- Verify screenshot 1's astronaut background with no online peers, screenshot 2's lunar/starfield background with online peers (including pause), and no background change when search hides all results. Verify bottom-right to top-left shrinking meteors, frozen gray offline stars and no inline connection error text. Repeat on narrow/wide iPhones to inspect image cropping and labels.

- Right-swipe or left-swipe a playlist row and use the playlist detail deletion menu. Each entry should show the same two choices plus Cancel. Cancel must leave everything unchanged. Keeping music must only delete the playlist. Deleting local music must remove the audio files, library songs, memberships in other playlists, and play stats; check after relaunch/foreground scanning. Test an empty playlist and a file-deletion failure (the playlist should remain, with an error).
- Import an audio file and its same-stem UTF-8 LRC together (select lyrics first as well as audio first). The lyrics should display without an audio-read error. Repeat with an already imported/deduplicated song, and with an existing local filename collision.
- Copy audio/LRC pairs into Documents using file sharing. Foreground the app, then add an LRC for an already indexed song and scan again. Check lyrics attach without replacing embedded or manually uploaded lyrics. Try uppercase `.LRC`, unmatched lyrics, invalid UTF-8, and ambiguous same-stem audio files; failed imports should explain the issue.
- Start, pause/resume, skip, and switch songs/videos before the end: counts should not change, while recently played songs should update at start. Let playback finish in list/repeat-one modes: each completion should add exactly one play, including in the background.
- Open the mini-player playlist selector, add the song to multiple playlists, then tap a checked playlist again. The check should disappear immediately, the sheet should stay open until Done/dismissal, and changes should survive relaunch. Verify the same toggle behavior from song rows and song details.
