# Stream Lounge TV v0.2.4 — automatic programme guide

Independent native tvOS app. This update retains v0.2.3's existing AVPlayer/VLC playback, playlist catalogue, sidebar and compact focus styles. No IPTV service, credentials or programme data is bundled.

## Update existing v0.2.3 repository using GitHub web

Replace `App.swift`, `Models.swift`, `Playback.swift`, `Settings.swift`, `project.yml`, and `README.md`. Add `EPG.swift` and `GuideUI.swift` at the repository root. Commit together. `Podfile` and `.github/workflows/build-tvos.yml` are unchanged. The complete source ZIP contains those unchanged files as well. `Tests/EPGSmoke.swift` is optional and is not part of the Xcode application target.

Run Actions → Build tvOS IPA → Run workflow. Download `StreamLoungeTV-unsigned` from the successful run, extract the IPA and sign/sideload using the existing method. Same bundle ID `com.streamlounge.tv`, tvOS 16 minimum, arm64. No new CocoaPods dependencies; EPG uses system zlib and Foundation XMLParser. Keep a backup of the previous IPA.

## EPG usage

1. Open Settings → EPG / TV Guide. Provider, Custom and EPGShare sources are enabled by default. Click Update all guides now. Existing M3U sources are migrated on refresh by re-reading their headers when possible. A playlist refresh will also discover provider header URLs.
2. Leave country codes blank to detect country tags (e.g. `UK: Sports`, `US | News`) in categories/channel names, or explicitly enter codes such as `UK, US, NG, ZA` (coverage is not guaranteed). Playlist-specific codes in Playlists → Edit override global codes. Codes are matched to country files listed by EPGShare01. Avoid requesting too many countries on constrained devices.
3. Add custom XMLTV or XMLTV.gz URLs in Playlists → Edit, separated by spaces. Xtream automatically uses `xmltv.php`; M3U reads `url-tvg`, `x-tvg-url` and `tvg-url` header fields. The application discovers EPGShare's index and downloads relevant country files. No all-countries file is downloaded.
4. Review per-playlist matched counts, feed errors and last update in EPG settings. Open TV Guide for the three-hour timeline; focus/select a channel to view programme details or enter a manual XMLTV channel ID. Use Automatic to remove a manual override and refresh. Guide data also appears in inline live TV channel rows and the Now Playing overlay.
5. Default: provider first, custom second, EPGShare third; manual mapping wins, then preference for currently populated schedules and matching precision, then source order when otherwise equivalent. A manual mapping requires knowing the XMLTV ID. Exact `tvg-id`, exact normalized name, quality-tag-stripped name, optional sibling borrowing. Ambiguous in-feed name matches are skipped. Time-shift and regional designators are conservatively preserved. Cross-source matching is heuristic; review mismatches manually.
6. Default refresh interval 12 hours while active; supports foreground checks, app launch and playlist imports. Default seven future days and one past day; global time offset. tvOS does not guarantee execution when suspended. Cache is separate per playlist, JSON in the tvOS Caches directory, may be evicted by system. Failed downloads preserve available older guides where practical. Safety limits: 20 feeds per refresh, 64 MiB downloaded file, 160 MiB expanded file, 300,000 retained programmes per feed, 400 programmes per matched channel, 64 MiB serialized cache per playlist. These limits favor bounded resource usage; large feeds may need narrower country selection.

## Verification and limitations

Passed in Linux Swift: core model/EPG type checks; Swift syntax parse for all app files; smoke test including XMLTV parsing, entity decoding, descriptions, relevant-channel filtering, manual overrides, exact-ID and normalized-name matching, ambiguous names, +1 preservation, M3U header discovery, country detection, v0.2.3 source migration, JSON snapshot round-trip and gzip. No Apple SDK available here: complete Xcode build, actual EPGShare network access, provider access, memory performance and Siri Remote timeline navigation have not been verified. Larger source catalogues may refresh slowly. Per-feed time offsets, SQLite indexing, source-specific manual links and a graphical XMLTV ID picker are not implemented in this version. External EPG coverage and availability depend on the service; only use sources you are authorized to access.

## Attribution

Selected IPTVnator v0.25.0 media classification and Xtream URL logic adapted under MIT, copyright 4gray (see LICENSE.md). IMD TV (https://github.com/majorleeevil/imd-tv, GPL-3.0) was studied as an architectural reference; the EPG Swift implementation is independently written, not a translation or inclusion of its Kotlin source. EPGShare01 (https://epgshare01.online/epgshare01/) provides external data subject to its own terms and availability. TVVLCKit 3.7.3 is VideoLAN's LGPL-2.1 library; public redistribution requires compliance with applicable upstream licence and third-party obligations. This application is not affiliated with any of those projects.
