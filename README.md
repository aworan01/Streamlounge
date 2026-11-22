# Stream Lounge TV v0.2.6 — full playlist names, persistent video output, fullscreen HDR diagnostics

Native SwiftUI tvOS IPTV player. This release updates v0.2.5 without changing the bundle identifier (`com.streamlounge.tv`), player engines (AVPlayer / TVVLCKit), IPTV sources or EPG cache. No IPTV streams or programme data are bundled. Use only sources you are authorized to access.

## Updating in your existing GitHub repository (web only)

Replace these root files together: `App.swift`, `Playback.swift`, `project.yml`, and `README.md`. Do **not** delete the existing `EPG.swift`, `Podfile`, `LICENSE.md` or `.github/workflows/build-tvos.yml`. The update ZIP contains only changed files; the full source ZIP contains all files including the unchanged files and the workflow.

Commit and run **Actions → Build tvOS IPA → Run workflow**. On success, download the `StreamLoungeTV-unsigned` artifact, sign it using your normal tvOS signing method, then install on Apple TV. This is an unsigned IPA build. Keep a copy of the previous installed/tested version.

## What changed

1. **Full playlist names in Live TV:** The source/filter column expands from 290 to 410 points. Rather than trusting a compact tvOS `Picker` to show an arbitrary name, the page now uses a wide, multiline button displaying the selected playlist name in full. It opens a spacious, scrolling selection sheet where each playlist name wraps without truncation.
2. **Inline-to-fullscreen video:** The previous implementation recreated `VideoHost` (and rebound TVVLCKit's `drawable`) every time a separate `PlayerSurface` appeared. The `PlaybackSession` now owns one persistent `VideoHost` with a single AVPlayerLayer and VLC drawable. Switching surfaces only moves the existing view to its new container. This targets the "video inline / audio-only fullscreen" failure mode.
3. **Manual recovery / diagnostics:** In fullscreen **Player** controls choose **Reconnect video output** to rebind the current engine's video output without importing playlists again. In **Info** the video surface attachment and dimensions appear alongside decoder resolution, engine and measured bitrate.
4. **Current playback and navigation retained:** All v0.2.5 TV Guide, Now Playing channel and group navigation, SD/HD/FHD/4K labels, EPGShare support, subtitles, favorites and the existing user data keys remain in place.

## GitHub installation (web only)

For an existing working v0.2.5 repository, upload the four changed files to the project root and commit. Keep `EPG.swift`, `GuideUI.swift`, `Models.swift`, `Settings.swift`, `Podfile`, `LICENSE.md` and `.github/workflows/build-tvos.yml` unchanged. Open **Actions → Build tvOS IPA → Run workflow**. Download `StreamLoungeTV-unsigned` from the successful run; sign and sideload with your established tvOS tool. Do not delete the installed previous version until the replacement works on your device.

## Suggested TV tests

1. In **Live TV**, select a playlist with a long name. It should appear over one or more readable lines, not as an ellipsis. Press Select to open the new full-width playlist chooser; check every long entry and remote focus.
2. Start a known working HD channel inline, enter fullscreen, and return inline several times. It should continue displaying video rather than going black.
3. Repeat step 2 on a 4K/HDR channel that previously played inline but went black fullscreen. In **Now Playing → Info**, inspect **Video surface**, **Resolution**, **Engine**, and **Bitrate**. If the screen is black, try **Player → Reconnect video output**.
4. For channels that never show video even inline, compare **Player → AVPlayer** and **Player → VLC**. Disable hardware decoding in Settings and reopen the channel as an additional diagnostic; it may reduce performance. Different codec, HDR or transport combinations may require further work.
5. Confirm Live TV, XMLTV EPG, source selection, favorites, Movies, Series and Siri Remote navigation remain functional.

## Validation and important limitations

- Source-level Swift parser checks passed on the revised files. Full tvOS compilation **has not been performed here** because the tvOS SDK and Xcode are unavailable in this environment. GitHub Actions and testing on your Apple TV are required to verify compilation and rendering.
- A persistent video surface is a targeted fix for view/layer replacement. It **does not guarantee playback of every 4K, HEVC, HDR10, Dolby Vision or MPEG-TS stream**. Some streams fail at decoding or are incompatible with the Apple TV hardware, available codecs or server packaging. Collect an exact problematic channel's codec/format, Info panel values and player's diagnostics before choosing further decoding changes.
- The player does not add a new third-party playback library in this patch; AVPlayer and TVVLCKit stay as they are.

## Project and third-party licences

The IPTVnator v0.25.0 utility/URL-construction adaptations remain under MIT, copyright 4gray; see `LICENSE.md`. IMD TV's GPL-3.0 EPG architecture was reviewed as a reference, but the included Swift EPG code is independently written. TVVLCKit 3.7.3 is subject to its VideoLAN LGPL-2.1 obligations. Check these licences and any linked dependencies before public distribution. The app is independently named and is not affiliated with IPTVnator, IMD TV or VideoLAN.
