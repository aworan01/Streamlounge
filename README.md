# Stream Lounge TV v0.2.5 — remote navigation, TV Guide playback, channel browser, quality labels

Native SwiftUI tvOS IPTV player. This release updates v0.2.4 without changing the bundle identifier (`com.streamlounge.tv`), player engines (AVPlayer / TVVLCKit), IPTV sources or EPG cache. No IPTV streams or programme data are bundled. Use only sources you are authorized to access.

## Updating in your existing GitHub repository (web only)

Replace these root files together: `App.swift`, `Models.swift`, `Playback.swift`, `Settings.swift`, `GuideUI.swift`, `project.yml`, and `README.md`. Do **not** delete the existing `EPG.swift`, `Podfile`, `LICENSE.md` or `.github/workflows/build-tvos.yml`. The update ZIP contains only changed files; the full source ZIP contains all files including the unchanged files and the workflow.

Commit and run **Actions → Build tvOS IPA → Run workflow**. On success, download the `StreamLoungeTV-unsigned` artifact, sign it using your normal tvOS signing method, then install on Apple TV. This is an unsigned IPA build. Keep a copy of the previous installed/tested version.

## What changed

1. **Sidebar skipping:** Removed competing manual Up/Down focus changes in the main sidebar and Settings category column. tvOS's native focus engine handles vertical movement; Right enters the highlighted section. Use centre/Select to open pages. This requires actual Siri Remote verification.
2. **Play from TV Guide:** Selecting a channel name (play icon) in the EPG timeline starts its current live stream in the fullscreen player. Selecting the adjacent schedule opens programme details and manual guide matching; that screen also has **Watch Live**, which opens inline playback in Live TV. Historical/future programme cells do **not** imply catch-up playback.
3. **Now Playing → Channels:** The channel browser starts with the current playlist and group, scrolls to and focuses the currently playing channel, and offers playlist and group menus on the left. Changing the group scrolls the resulting channel list to its first item. The full list is no longer restricted by the Live TV page's search or category filters. Previous/Next stays within the currently playing playlist.
4. **Live TV playlist header:** A dedicated one-line **Playlist** heading, a compact selector and a separate full source name (wrappable) prevent a long playlist name from being silently truncated.
5. **Now Playing → Quality:** The icon displays **SD, HD, FHD or 4K** based on the real video raster size reported by the active decoder. Before dimensions are reported, it shows `—` instead of falsely displaying 4K. The Quality and Info panels show the classification and actual resolution, and the existing player-dependent bandwidth options remain.

## On-device test checklist

- Open Dashboard, move Down once per menu item to Movies. Confirm no menu items skipped. Repeat in reverse and in Settings.
- Open TV Guide, select the **channel name** to play live. Exit the player; select the **programme cell** to open details and then select **Watch Live**.
- Play a channel near the end of a long playlist, enter fullscreen → **Channels**. Verify it scrolls to the active channel and the selected channel is highlighted. Change groups and playlists from the left side and play a channel from a different group.
- In Live TV select a playlist with a very long name; verify its full name remains visible below the selector.
- Play known 576p, 720p, 1080p and 2160p streams; the Quality icon should show SD, HD, FHD and 4K respectively. A stream with no detected video should show `—`. This indicator is informational, not a quality selector or a guarantee of picture availability.

## Validation and limitations

- Passed: Swift syntax parsing of all application source files under Linux Swift; standalone type checking of the Foundation/EPG core; previous EPG import/matching smoke tests; new `Tests/QualitySmoke.swift` for quality-tier mapping; ZIP archive integrity. Neither TVVLCKit nor Apple's tvOS SDK is installed in the container.
- **Not yet verified:** Entire project compiling in Xcode, focus movement on Apple TV, fullscreen channel-list auto-scroll, or performance with a large programme catalogue. Report any compile errors from the GitHub Actions `build-log` artifact. Do not treat this release as device-tested until you install it.
- This is live playback from EPG, **not catch-up/time-shifted playback**. EPG match coverage still depends on external data and the provider.

## Project and third-party licences

The IPTVnator v0.25.0 utility/URL-construction adaptations remain under MIT, copyright 4gray; see `LICENSE.md`. IMD TV's GPL-3.0 EPG architecture was reviewed as a reference, but the included Swift EPG code is independently written. TVVLCKit 3.7.3 is subject to its VideoLAN LGPL-2.1 obligations. Check these licences and any linked dependencies before public distribution. The app is independently named and is not affiliated with IPTVnator, IMD TV or VideoLAN.
