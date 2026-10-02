# Local Music — SwiftUI iOS Player

A modern, local-first music player built with SwiftUI and AVFoundation for iOS 16 and later.

## Features

- Imports multiple audio and video files with `UIDocumentPickerViewController`.
- Copies imported audio into the app's Documents/Imported Music directory.
- Recursively detects compatible files copied directly into the app's Documents directory.
- Reads title, artist, album, duration, and embedded artwork with `AVURLAsset`.
- Plays through `AVPlayer` with play/pause, seeking, previous/next, shuffle, list repeat, and repeat-one modes.
- Provides Home, Songs, Artists, and Playlists tabs with global search.
- Tracks recent plays and play-count rankings locally.
- Supports persistent playlists; a song can belong to multiple playlists.
- Cleans deleted songs out of playlists and playback statistics automatically.
- Shows local MP4, MOV, and M4V videos on the matching artist page and plays them with the system video player.
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

1. **Files picker:** tap the import button in the app. Selected files are securely copied into `Documents/Imported Music` and indexed immediately.
2. **Finder or iTunes file sharing:** connect the iPhone to a Mac or PC, open its Files/File Sharing section, select **Local Music**, and copy audio files into the app. Reopen or foreground the app to scan Documents automatically.

The project enables both `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Common extensions scanned by the library are MP3, M4A, WAV, AAC, AIF/AIFF, CAF, FLAC, MP4, MOV, and M4V. Actual decoding support depends on the iOS version and the file's codec.

## Structure

- `Models/Track.swift` — persisted audio model and duration formatting.
- `Models/Playlist.swift` — playlist, artist grouping, and play-stat models.
- `Services/LocalMusicLibrary.swift` — document import, sandbox copying, metadata, persistence, and deletion.
- `Services/MusicDataStore.swift` — persistent playlists, recent history, and rankings.
- `Services/AppSettings.swift` — app language, notification preference, and localized labels.
- `Player/MusicPlayerViewModel.swift` — AVPlayer engine and playback state.
- `Views/RootView.swift` — global toolbar, search, tabs, import flow, and floating player.
- `Views/FeatureViews.swift` — Home, Songs, Artists, Playlists, and detail screens.
- `Views/GlassComponents.swift` — reusable dark glass cards, rows, and backgrounds.
- `Views/MiniPlayerView.swift` — persistent bottom controls.
- `Views/NowPlayingView.swift` — artwork, seek slider, controls, and repeat mode.
- `Views/DocumentPicker.swift` — SwiftUI bridge for the system file picker.

## Notes

The repository is generated on Windows, where Xcode and the iOS SDK are unavailable. Build and signing must be performed on macOS. Add an AppIcon asset in Xcode before App Store distribution.
