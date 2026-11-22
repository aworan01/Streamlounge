# Stream Lounge TV v0.3.1 — tvOS runtime hotfix

This update corrects four issues reported after testing v0.3.0 KSPlayer on Apple TV.

- **LAN import storage**: imported files are written into `Library/Caches/imported-m3u`, not the rejected Application Support folder. Old accessible files are migrated on startup. Cache files are *purgeable* by tvOS, so a removed file must be re-imported; playlist source metadata, channel catalog and favorites remain tracked separately.
- **LAN import acknowledgement**: the phone/browser now receives success only after the playlist was saved and loaded successfully. A failed import displays a visible error on the Playlists page.
- **App icon**: `Assets.xcassets/App Icon.brandassets` now matches Xcode's `ASSETCATALOG_COMPILER_APPICON_NAME: App Icon`, with complete 400×240 and 1280×768 layered art from the user's supplied TV artwork. GitHub Actions verifies that the icon asset and Info.plist entry were actually compiled.
- **KSPlayer controls**: Stream Lounge's focusable fullscreen toolbar now controls KSPlayer play/pause, seeking, audio, subtitle, and video-track selection. The embedded UIKit toolbar is hidden from Siri Remote focus.
- **KSPlayer 4K diagnostic**: Settings → Playback → KSPlayer decoder provides `Native first` or `FFmpeg first`. Neither guarantees playback of an unsupported HEVC profile, DRM stream, or resource-intensive 4K track.

**Build:** replace existing files with this complete source folder, *delete* the old `Assets.xcassets/AppIcon.brandassets` folder in your GitHub repository, and upload the renamed `Assets.xcassets/App Icon.brandassets` folder. Keep all directories and `.github/workflows` paths intact. Then use Actions → Build KSPlayer tvOS IPA (experimental). A GitHub website ZIP upload does not automatically unpack: upload extracted files/directories through a git client or GitHub Codespaces if preserving nested paths is difficult.

**Important:** The fix is source-validated but not Xcode-compiled in this environment. Test on hardware and attach the build log if GitHub reports any Swift/package or asset-catalog errors. For 4K playback problems, share the Apple TV generation, stream codec/profile/container (without credentials), and playback diagnostics; a missing picture alone cannot establish the decoder's root cause.

**Licensing:** Stream Lounge TV is independent of the IPTVnator brand. IPTVnator code is MIT licensed (4gray), VideoLAN TVVLCKit is LGPL-2.1, and KSPlayer 5.6.2 is GPL-3.0. Distribution of the experimental KSPlayer build must comply with applicable GPL conditions. Use only authorized playlists and streams.

---

# Stream Lounge TV v0.3.0 — test build

A separately named **native SwiftUI tvOS** IPTV app adapting selected IPTVnator v0.25.0 logic. This release builds on the tested v0.2.6 code. It does **not** include channels, subscriptions, movies, streaming credentials, or paid content. Use authorized playlists.

## Builds available

**Recommended first: `Build tvOS IPA`** in `.github/workflows/build-tvos.yml`. Uses `project.yml`, AVPlayer and TVVLCKit 3.7.3, on macos-15/Xcode 16.4. It intentionally does **not** link KSPlayer. Same `com.streamlounge.tv` bundle ID, so it can update the current app while preserving data when signed with the same signing identity. Do not uninstall your working version until you have a backup.

**Experimental: `Build KSPlayer tvOS IPA (experimental)`** in `.github/workflows/build-tvos-ks-experimental.yml`. Uses `project.ksplayer.yml`, `KSPlayer` 5.6.2, macos-26 with Xcode 26.2, while retaining AVPlayer and TVVLCKit for comparison. KSPlayer is visible in the settings **only if that experiment actually compiles**. The KSPlayer integration has not been verified by a complete tvOS Xcode build and may require follow-up fixes; don't overwrite the working build with it before testing. GPL-3.0 obligations apply to redistribution of this linked build. Experimental KSPlayer playback has basic embedded controls; AVPlayer/VLC features such as track selection, bitrate reporting and saved positions are **not** yet wired to the KSPlayer engine.

## Updating from v0.2.6 through the GitHub website

1. Download and extract the **update ZIP**. In the repository root replace `App.swift`, `Playback.swift`, `Models.swift`, `Settings.swift`, `project.yml`, and `README.md`.
2. Add `ViewingData.swift`, `MovieDetailsView.swift`, `LocalM3UServer.swift`, and `KSPlayerBridge.swift` to the repository root.
3. Add `project.ksplayer.yml` to the root and `.github/workflows/build-tvos-ks-experimental.yml` at that **exact path**. The original `.github/workflows/build-tvos.yml`, `EPG.swift`, `GuideUI.swift`, `Podfile`, and `LICENSE.md` stay in place.
4. Commit the changes. From **Actions**, run **Build tvOS IPA** (the standard AVPlayer/VLC workflow) first. After a successful run, obtain the **unsigned** IPA from Artifacts, sign it using your established method, and test on Apple TV. The KSPlayer workflow is a separate, optional second build.
5. Never upload playlist credentials or real M3U contents to a public GitHub repository. Only the app source files belong in the repo.

If starting from scratch, the **complete ZIP** includes the original + revised source, both workflows and the necessary tests.

## Scope delivered

### 1 — 4K/HDR stability and audio

- Automatic playback uses AVPlayer first for compatible HLS 4K/HDR streams. VLC is prioritized for non-native file extensions such as MKV/AVI/TS and remains an explicit option. No promised blanket 4K, HDR or Dolby Vision support: device capabilities, video bit depth/profile, container and transport still determine playback.
- Per-channel crash breadcrumb: if the previous playback ends without normal stop, the next app launch marks the affected channel for a native-player recovery attempt **without an immediate VLC fallback**. The marker can also be created by abruptly terminating the app; it is a diagnostic/recovery heuristic, not a crash report or guaranteed fix.
- The AVPlayer **Audio** menu no longer presents the audio-disabled choice. VLC audio-track IDs are checked before selection, and **Now Playing → Audio → Restore default sound** is available. Unplayable codecs and mislabelled provider tracks can still be silent.
- The existing `Now Playing → Info` stream diagnostics and persistent video rendering surface remain in place.

### 5 — Movie details and resume

- Movie detail sheet with posters, description, year, genre, runtime and ratings **where the existing source supplies those fields**. For existing Xtream movie entries this calls `get_vod_info`; M3U movies retain the name/logo from their playlist, and no third-party metadata provider is contacted.
- Play, Resume, Restart and Favorite actions; local VOD progress stored on the device for AVPlayer/VLC (recorded about every five seconds). A title watched to at least 95% is marked complete. Resume is not promised for live streams or the experimental KSPlayer engine.

### 6 — Playlist management

- **Playlists → Import M3U from phone/computer** starts an opt-in local HTTP receiver on port `8877`. Visit the displayed LAN URL from a device on the same network, choose an M3U file and enter the six-digit PIN shown on Apple TV. The transfer is unencrypted HTTP on your LAN and should be used only on a trusted private network. The listener stops after one transfer or when you leave the Playlists page.
- Local playlists (up to 8 MB) are stored in app support storage, not in UserDefaults. Refresh rereads the saved file. Existing URL/pasted M3U and playlist account editing remain available.
- Move Up / Down controls reorder sources without changing their IDs; edit/refresh/remove remain available.

### 7 — Dashboard and settings

- Continue Watching rail for unfinished movies, plus existing Recent, Favorites, Movies, Series and source-management navigation. Source-provided posters and locally stored progress indicators appear on movie tiles.
- Settings → Dashboard: startup screen selection, remember-last-channel replay when returning to Live TV, optional playlist refresh on launch. Settings → Data management: clear viewing history and clear watch progress.
- Preserve the v0.2.6 single-line branding, playlist names, compact focus styling, EPG, inline/fullscreen modes and playback controls. Full visual parity with IPTVnator is **not** claimed.

### 8 — KSPlayer evaluation

- The optional experimental build links tagged KSPlayer `5.6.2`, whose Package.swift uses Swift tools 6.2. The default Xcode 16.4 build cannot compile that package, so its workflow uses macos-26 and Xcode 26.2.
- Choose KSPlayer in Settings → Playback or in Now Playing → Player **only in the successful experimental build**. This is an evaluation of its video engine, not yet complete replacement of the existing UHF-style Now Playing overlay or parity with VLC controls.

## First test sequence

1. Confirm HD live playback, EPG and Siri Remote navigation work without regression.
2. Try 4K/HDR streams in **Auto**, then manually with **AVPlayer** and **VLC**. If an app crash occurs, reopen and try the same channel; report whether the native recovery mode appears.
3. Open a multi-audio stream: select each advertised audio option, then try **Restore default sound**. Report audio codec/language/engine if one remains silent.
4. Open an existing movie, play for a minute, close and select Resume. Note the exact engine used.
5. Import an M3U using the phone/computer transfer page; test refresh, rename and Up/Down reorder.
6. Only after standard build testing, optionally run **Build KSPlayer tvOS IPA (experimental)** and provide the complete build log if it fails.

## Testing completed here

- Swift parser check on all app `.swift` files: passed.
- Linux Swift type-check for the platform-independent `Models.swift` and `ViewingData.swift`: passed.
- Local regression executable for M3U parsing, media type, 4K quality classification, resume bounds and time formatting: passed.
- Project/workflow YAML parsed and ZIP CRC checked.
- **Not performed:** full Xcode/tvOS SDK compilation; VLC/KSPlayer linking; testing live 4K/HDR streams; testing Siri Remote focus on a physical Apple TV; local network transfer on real tvOS. Do not assume these are proven until the GitHub Actions build and device test succeed.

## Licensing and third-party services

- Original IPTVnator v0.25.0 code snippets adapted here: MIT, copyright © 2019–2026 4gray. Respect its name/logo trademarks; this is not an official IPTVnator release. See `LICENSE.md`.
- TVVLCKit 3.7.3 is subject to VideoLAN's LGPL-2.1 terms.
- Optional KSPlayer 5.6.2 source and binaries are GPL-3.0, subject to its dependency licences. If distributing a combined KSPlayer build, assess and comply with all applicable open-source requirements. The normal AVPlayer/VLC build does not link KSPlayer.
- IMD TV's GPL-3.0 EPG design was reviewed as a reference, but the bundled Swift EPG implementation is independent. Neither the app nor the build package includes external programme or channel data.
