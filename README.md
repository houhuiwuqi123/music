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
- Adds Candy广场 after Artists: an animated, searchable starfield of online listeners on a libp2p Kademlia DHT network shared with the Vue web client (`web/`); current songs are published by content hash (CID) and transferred peer-to-peer over WebRTC with block-level verification and resume across network switches.
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

The deployment target is iOS 16.0. The Xcode project resolves the WebRTC binary Swift Package when first opened/built. Candy广场 joins the DHT through the node list at `https://music.webtrc.eu.cc/api/bootstrap` (gateway `wss://music.webtrc.eu.cc/ws`) and gets STUN/TURN settings from the node. No insecure ATS exception is needed.

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

### Candy广场 (DHT network)

Candy广场 is a decentralized network of iOS apps and browsers. Architecture, protocols and deployment: [backend/README.md](backend/README.md).

- **Joining.** The app fetches `https://music.webtrc.eu.cc/api/bootstrap` (the initial node list, cached for later launches) and connects to a lightweight node's `/ws` gateway. It authenticates with its own Ed25519 libp2p identity, which is kept in the Keychain; the peer ID is the same one js-libp2p/go-libp2p would compute.
- **Publishing.** Playing a local song hashes it in one streaming pass: the whole-file SHA-256 becomes CIDv1 raw (`bafkrei…`), and a hash is kept for every 1 MiB block. The node PROVIDEs that CID in the Kademlia DHT on the app's behalf. The app signs a plaza announcement (nickname, avatar, region, current song, file) that is gossiped to every node and browser. Pausing keeps the share, switching songs replaces it, and disabling publicity or clearing playback sends a signed `bye`. Only share music you have permission to distribute.
- **Discovery and download.** Tapping a star runs GET_PROVIDERS for the CID through the node. Each provider is offered a full (non-trickle) SDP via the node it is attached to, and the file then streams over a direct WebRTC DataChannel `auru-file/1`. The receiver writes to disk as it goes, checks every 1 MiB block against the sender's block list, and finally checks the whole file against the CID before saving it to `Documents/Candy Downloads`. Partials live in `.partial` for 24 hours and are keyed by content, so any provider of the same file can continue them.
- **Network switches.** `NWPathMonitor` watches Wi-Fi ↔ cellular changes. On a change the gateway socket reconnects immediately (rotating bootstrap nodes, with exponential backoff and jitter), live peer connections are dropped, and downloads resume from the last verified block with freshly discovered providers. Returning to the foreground re-checks the connection. A 25-second WebSocket ping detects dead links.
- **Web.** The Vue page in `web/` is a full js-libp2p DHT client. It lists what iOS users are listening to and can share files manually; a shared file shows up and downloads exactly like a song an iOS user is playing. Uploads are served only while the page stays open.
- **UI.** Stars show avatar, nickname · region, and the song title (web peers show `分享：<file>`). Offline stars turn gray and freeze, then disappear 60 seconds later. The status capsule, profile sheet, transfer tasks (progress / cancel / retry / clear partial) and receive history are unchanged.

Source devices must stay online and in the foreground to upload; the app does not misuse background modes. With two symmetric NATs a direct path needs TURN (configure `TURN_URLS` on the node).

Checks: `node scripts/verify-candy-connection.cjs` (source consistency across Go/JS/Swift; `--live` checks the public gateway handshake). On macOS also run `node scripts/verify-candy-disk.cjs` (compiles the production codecs and disk actor, cross-verifies a Swift-signed announcement with the JS implementation) and `node scripts/verify-candy-ios.cjs` (unsigned simulator build). Backend and web tests: `go test ./...` in `backend/`, `npm test` in `web/`.

### Regression checks on iOS

- Two phones plus one browser: each sees the others' stars or list entries. Edit nickname/avatar and confirm it updates elsewhere. Toggle publicity in Settings: the star disappears immediately and the setting survives relaunch.
- Play songs on phone A; download from phone B and from the browser (MP3/M4A/FLAC, 5/20/200 MB) and compare SHA-256 with the originals. Share a file from the browser and download it on a phone. Paste a CID into the browser's "按哈希查找".
- During a 200 MB download, switch the receiver between Wi-Fi and cellular, toggle airplane mode for 30 seconds, and background/foreground the app. The download must resume from a verified 1 MiB boundary rather than zero, and the final hash must match. Repeat on the sender side: the receiver retries and resumes once the sender is back.
- Kill the sender: its star turns gray within seconds on its own node (90 seconds elsewhere at most) and is removed 60 seconds later.
- Run two nodes (`NODE_BOOTSTRAP`) and attach the phones to different nodes: plaza, discovery and transfer must still work. Test forced-TURN networks separately.
- Verify the astronaut background with no online peers, the lunar background with peers (including paused ones), and no background change when search hides every result.

- Right-swipe or left-swipe a playlist row and use the playlist detail deletion menu. Each entry should show the same two choices plus Cancel. Cancel must leave everything unchanged. Keeping music must only delete the playlist. Deleting local music must remove the audio files, library songs, memberships in other playlists, and play stats; check after relaunch/foreground scanning. Test an empty playlist and a file-deletion failure (the playlist should remain, with an error).
- Import an audio file and its same-stem UTF-8 LRC together (select lyrics first as well as audio first). The lyrics should display without an audio-read error. Repeat with an already imported/deduplicated song, and with an existing local filename collision.
- Copy audio/LRC pairs into Documents using file sharing. Foreground the app, then add an LRC for an already indexed song and scan again. Check lyrics attach without replacing embedded or manually uploaded lyrics. Try uppercase `.LRC`, unmatched lyrics, invalid UTF-8, and ambiguous same-stem audio files; failed imports should explain the issue.
- Start, pause/resume, skip, and switch songs/videos before the end: counts should not change, while recently played songs should update at start. Let playback finish in list/repeat-one modes: each completion should add exactly one play, including in the background.
- Open the mini-player playlist selector, add the song to multiple playlists, then tap a checked playlist again. The check should disappear immediately, the sheet should stay open until Done/dismissal, and changes should survive relaunch. Verify the same toggle behavior from song rows and song details.
