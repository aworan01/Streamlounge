# Stream Lounge TV v0.3.1 — KSPlayer track-selection build hotfix

The GitHub KSPlayer workflow failed with two Swift errors in `KSPlayerBridge.swift`
(lines 60 and 66): `type any MediaPlayerTrack cannot conform to MediaPlayerTrack`.

## What changed

`selectAudio(_:)` and `selectVideo(_:)` now select the concrete
KSPlayer track types (AVMediaPlayerTrack, AVMediaSelectionTrack,
FFmpegAssetTrack) before invoking `select(track:)`.

The rest of the application, including the existing app icon, M3U import,
EPG, VLC/AVPlayer playback and KSPlayer decoder settings, is unchanged.

## Apply

Replace `KSPlayerBridge.swift` at your GitHub repository root with the file
in this ZIP. Do not change other files. Commit the change and run
**Actions → Build KSPlayer tvOS IPA (experimental) → Run workflow**.

This fixes the two diagnosed source-level errors. Full compilation has not
been verified locally because the tvOS Xcode SDK is unavailable here.
