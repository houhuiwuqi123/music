# Local Music — SwiftUI iOS Player

A small local-first music player built with SwiftUI and AVFoundation.

## Features

- Imports multiple MP3, M4A, and WAV files with `UIDocumentPickerViewController`.
- Copies imported audio into the app's Documents/Imported Music directory.
- Reads title, artist, album, and duration metadata with `AVURLAsset`.
- Plays through `AVPlayer` with play/pause, seeking, previous/next, list loop, and repeat-one modes.
- Includes a local library, persistent mini player, and full Now Playing screen.
- Persists the imported library index as JSON and supports swipe-to-delete.
- Uses the playback audio session and background audio mode.

## Run

1. Copy this folder to macOS with Xcode 15 or newer.
2. Open `MusicPlayer.xcodeproj`.
3. Select the **Local Music** target.
4. Under **Signing & Capabilities**, choose your Apple Developer Team and change the bundle identifier if needed.
5. Choose an iPhone simulator or connected iPhone and press **Run**.
6. Tap **Import Music** and choose MP3, M4A, or WAV files from the Files picker.

The deployment target is iOS 16.0. No third-party packages are required.

## Structure

- `Models/Track.swift` — persisted audio model and duration formatting.
- `Services/LocalMusicLibrary.swift` — document import, sandbox copying, metadata, persistence, and deletion.
- `Player/MusicPlayerViewModel.swift` — AVPlayer engine and playback state.
- `Views/LibraryView.swift` — music library and import flow.
- `Views/MiniPlayerView.swift` — persistent bottom controls.
- `Views/NowPlayingView.swift` — artwork, seek slider, controls, and repeat mode.
- `Views/DocumentPicker.swift` — SwiftUI bridge for the system file picker.

## Notes

The repository is generated on Windows, where Xcode and the iOS SDK are unavailable. Build and signing must be performed on macOS. Add an AppIcon asset in Xcode before App Store distribution.
