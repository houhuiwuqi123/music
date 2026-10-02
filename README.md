# AURA MUSIC — SwiftUI iOS Player

A modern, local-first music player built with SwiftUI and AVFoundation for iOS 16 and later.

## Features

- Imports multiple audio and video files with SwiftUI's native `fileImporter`.
- Copies imported audio into the app's Documents/Imported Music directory.
- Recursively detects compatible files copied directly into the app's Documents directory.
- Reads title, artist, album, duration, and embedded artwork with `AVURLAsset`.
- Plays through `AVPlayer` with play/pause, seeking, previous/next, shuffle, list repeat, and repeat-one modes.
- Provides Home, Songs, Artists, and Playlists tabs with global search.
- Tracks recent plays and play-count rankings locally.
- Supports persistent playlists; a song can belong to multiple playlists.
- Supports custom covers for songs and playlists through the native Files importer.
- Provides song details with metadata, playlist assignment, and permanent local deletion.
- Provides playlist details with cover upload and add/remove song management.
- Song rows provide an ellipsis menu for details, playlist assignment, play-next, rename, and permanent deletion.
- Deduplicates imported and discovered songs by normalized title, artist, album, and duration.
- Song deletion asks whether to hide the song from the library while keeping its sandbox file or permanently delete the app's local copy.
- Music and playlist rows support native full-swipe deletion with confirmation choices.
- Empty artist and playlist data no longer render empty glass cards.
- The app icon asset is configured at `MusicPlayer/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
- Reads embedded lyrics and supports uploaded UTF-8 LRC/text lyrics with synchronized scrolling in Now Playing.
- Cleans deleted songs out of playlists and playback statistics automatically.
- Shows local videos in global search and on the matching artist page, then plays them with the system video player.
- Includes a floating mini player and full Now Playing screen in a dark glass design.
- Includes Chinese/English settings, notification permission, version, policy, and support views.
- Sends an optional local notification after media import completes.
- Uses the playback audio session and background audio mode.

## Run

1. Copy this folder to macOS with Xcode 15 or newer.
2. Open `MusicPlayer.xcodeproj`.
3. Select the **Local Music** target.
4. Under **Signing & Capabilities**, choose your Apple Developer Team and change the bundle identifier if needed.
5. Choose an iPhone simulator or connected iPhone and press **Run**.
6. Tap the import button and choose audio files from the Files picker.

The deployment target is iOS 16.0. No third-party packages are required.

## How local files are recognized

The app cannot read arbitrary files elsewhere on an iPhone because iOS apps run in a sandbox. Use either supported workflow:

1. **Native Files picker:** tap the import button in the app. SwiftUI `fileImporter` opens the system Files interface. Selected files from On My iPhone, iCloud Drive, Downloads, or an installed provider are accessed through security-scoped URLs, coordinated with the provider, copied into `Documents/Imported Music`, and indexed immediately.
2. **Finder or iTunes file sharing:** connect the iPhone to a Mac or PC, open its Files/File Sharing section, select **Local Music**, and copy audio files into the app. Reopen or foreground the app to scan Documents automatically.

The project enables both `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. The scanner accepts every file type declared by iOS as audio or movie. It also explicitly recognizes common audio extensions including MP3, AAC, M4A/M4B, WAV, AIFF, CAF, FLAC, AC3/EAC3, AMR, OGG/OGA, Opus and WMA, plus common video containers including MP4, MOV, M4V, MPEG, 3GP, AVI, MKV, WebM, MTS/M2TS and TS. FLAC is supported directly through AVFoundation on current iOS versions. Playback of any container still requires its internal codec to be supported by the installed iOS version.

### Development and Simulator files

- In Simulator, first place media in a location visible to the simulated **Files** app, such as iCloud Drive or a provider exposed in Browse, then use the app's import button.
- On a development iPhone, choose files from **On My iPhone**, **Downloads**, iCloud Drive, or another enabled Files provider.
- Provider and iCloud files may be placeholders. The app uses `NSFileCoordinator` while its security-scoped permission is active, allowing the provider to download the selected file before it is copied.
- Direct access to arbitrary Mac folders or paths outside the iOS sandbox is intentionally unavailable. Files must be selected through `fileImporter` or copied through Finder file sharing.

## Structure

- `Models/Track.swift` — persisted audio model and duration formatting.
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
