# Stream Lounge TV v0.2.1 — test release

Independent native tvOS adaptation of selected IPTVnator v0.25.0 functionality. Not affiliated with the IPTVnator project. Original source modules adapted in Models.swift are MIT licensed (see LICENSE.md). Use your own authorized streams.

## Upgrade on GitHub (browser only)

1. Extract the ZIP. Keep the existing repository and bundle identifier (`com.streamlounge.tv`). In GitHub upload/replace App.swift, Models.swift, Playback.swift, Settings.swift, project.yml, Podfile, README.md, LICENSE.md at repository root.
2. Replace `.github/workflows/build-tvos.yml` using GitHub's web editor. Do not upload the workflow at the root; if ZIP extraction hides `.github`, use the separately supplied workflow.
3. Under Actions → Build tvOS IPA → Run workflow. The runner generates the project, installs pinned TVVLCKit 3.7.3 using CocoaPods, builds the workspace for arm64 Apple TV hardware, verifies the executable and packages the unsigned IPA. The first dependency download is large.
4. Download `StreamLoungeTV-unsigned` from the completed job's Artifacts, unzip the artifact, then sign/sideload the IPA using your own signing setup. The unsigned file cannot launch unmodified.
5. If compilation fails, send the full build log (including the failing step). No macOS/tvOS SDK is available in the preparation environment; Swift syntax and model type-checking were performed locally, but integration and runtime tests are pending.

## v0.2.1: remote and fullscreen revision

If v0.2.0 is already building, replace only App.swift, Playback.swift, Settings.swift and project.yml at the root of the working repository. Keep Models.swift, Podfile, LICENSE.md and the existing corrected workflow. The bundle identifier and catalog schema are unchanged. No new dependency is introduced.

- Sidebar: one-line app name and navigation labels. Press Right on a sidebar entry to enter the relevant page directly. Settings has explicit category-to-option focus routing.
- Channel rows: wider name column, smaller icon and adaptive text that tries regular size, compact size and finally full wrapping without truncation. Settings > Appearance > Text size offers Compact, Standard and Large.
- Fullscreen: video fills the available screen; focus starts on Play/Pause. The bottom control bar offers previous/next, channel list, source switching, favorites, audio, subtitles, quality, info, engine selection, hide and close. Press Select or a directional button to show hidden controls; Back closes a panel, hides the overlay, or exits fullscreen depending on state. Play/Pause remote button toggles playback. Close returns to inline playback for live TV.
- Source lists the currently playing stream and other imported streams of the same media kind with a matching name or nonempty TVG ID. It cannot discover sources not imported.
- Audio and subtitle options are actual tracks made available by the active AVPlayer or VLC engine; external subtitle download is not implemented. Quality on AVPlayer sets a preferred adaptive bitrate ceiling (not a fixed resolution); VLC lists available video tracks, not individual HLS variants. No forced reduction of resolution by default. Info reports engine, dimensions/availability and AVPlayer's observed bitrate when available, not a full codec/HDR analysis.
- Actual tvOS/Xcode compilation and remote testing remain required; focus APIs and VLC track bindings need device validation. Swift syntax was checked locally, not type checked against SwiftUI or TVVLCKit.

## What's new in v0.2.0

- Persistent sidebar, dashboard with recent/favorites and VOD, source/category/channel columns, inline player, fullscreen expansion, next/previous and manual engine switching.
- Dedicated settings for engine, buffering, VLC hardware decoding, two dark themes, XMLTV refresh, clear history and About.
- AVPlayer remains available; Auto starts VLC for UHD/4K-named entries and MKV, or falls back to VLC if AVPlayer fails/no picture is ready after 15 seconds. Frame readiness is a heuristic and may cause a fallback on audio-only or slow streams. Choose AVPlayer manually to avoid fallback. Software decoding is an experimental troubleshooting option; results depend on device, formats and provider.
- Visible playback engine, reported dimensions and AVPlayer observed network bitrate. Not a complete codec/HDR analyzer.
- Original M3U and Xtream source models retained, with existing playlist/favorite/history keys. Upgrading in place with the same signing identity may retain data; tvOS may evict cached catalogs. Avoid removing the working app until testing the replacement, particularly if you need its data.

## Test 4K audio-only issue

Settings → Playback → VLC; leave hardware decoding enabled. Select the same 4K channel; note the engine, resolution, sound and picture. If the picture remains black, stop the stream, disable hardware decoding and reopen. Try AVPlayer manually for comparison; report the result. For a radio-only service use AVPlayer explicitly if needed. Do not share private playlist credentials in logs. No universal 4K guarantee; DRM, codecs, network and device capabilities still apply.

## Known limitations

Not a feature-complete IPTVnator replica. Stalker, catch-up, grouped M3U series, full multi-channel EPG timeline, cloud/local file imports, watch progress, parental control, stream authentication headers, comprehensive codec/HDR diagnostics and automatic reconnect are not implemented. Basic XMLTV supports uncompressed XML and one loaded guide at a time. Switching away from Live TV stops the inline stream. TV remote layout and focus need device testing. Imported account credentials and URLs remain in local preferences/cache from the prior version; avoid sharing these files.

## Third-party notices and distribution

IPTVnator source reference: https://github.com/4gray/iptvnator/tree/v0.25.0 (MIT; upstream trademark and logo are not used as app identity). TVVLCKit 3.7.3 is distributed by VideoLAN under LGPL 2.1 (see upstream COPYING.txt and CocoaPods spec). VLC source: https://code.videolan.org/videolan/VLCKit ; libVLC: https://code.videolan.org/videolan/vlc . Dependency spec: https://github.com/CocoaPods/Specs/blob/master/Specs/b/f/5/TVVLCKit/3.7.3/TVVLCKit.podspec.json . Binary source archive: https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.3-319ed2c0-79128878.tar.xz . This package does not distribute that binary itself. Before redistributing compiled IPA builds, comply with applicable VLC/LGPL and transitive library requirements (including notices, corresponding source and relinking/reverse-engineering rights where required). This test package is intended for your own build and device testing.
