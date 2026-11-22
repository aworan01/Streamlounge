# Stream Lounge TV 0.1.0 (experimental)

An unofficial native SwiftUI tvOS implementation adapting selected code and behavior from [IPTVnator v0.25.0](https://github.com/4gray/iptvnator/tree/v0.25.0). It is not the official app or a full feature-equivalent port. No original branding is included. MIT upstream notice in LICENSE.md. Adapted source modules:
- `libs/shared/m3u-utils/src/lib/m3u-vod-detection.util.ts` — M3U VOD detection, translated subset.
- `libs/portal/xtream/data-access/src/lib/services/xtream-url.service.ts` — live, movie, series URL construction, translated subset.

## Build through GitHub's website (no Mac, terminal, signing keys or account secrets needed)

1. Create a new repository at https://github.com/new (suggested name `StreamLoungeTV`). Select Public or Private as desired, and initialize with a README. GitHub-hosted standard runners are normally free for public repositories; private repositories may use billed minutes.
2. Extract this source ZIP on your computer. On the repository's Code tab, click Add file > Upload files. Upload `App.swift`, `Models.swift`, `project.yml`, `LICENSE.md` to the ROOT (not inside an extra directory). Commit changes. You can replace the generated README with this file if desired.
3. On the Code tab, click Add file > Create new file. In the filename field enter **.github/workflows/build-tvos.yml** exactly. Open the workflow file from the extracted ZIP (it may be hidden), or use the separately supplied workflow file, and copy its entire text into GitHub. Commit to the default branch. GitHub must be allowed to run Actions (Settings > Actions > General). Do not upload just the ZIP archive to the repository.
4. Select Actions > Build tvOS IPA > Run workflow > Run workflow. A push to main/master with changed source/workflow also triggers a build automatically, so avoid starting duplicate runs if one is already running.
5. When green, open the completed run and download `StreamLoungeTV-unsigned` under Artifacts. Extract the downloaded artifact ZIP to find `StreamLoungeTV-unsigned.ipa`.
6. Use your Apple TV sideloading/signing tool (e.g. ATVLoadly if its signing service and device support work) to sign and install. An unsigned IPA cannot run directly on retail Apple TV. Pair the correct Apple TV, use a compatible provisioning profile and signing identity. Device installation is not tested here.

## In this source package

- Native tvOS 16+ SwiftUI layout; focus-based remote navigation, category and source filtering, search, channel artwork.
- Remote M3U/M3U8 URL import and pasted text input; direct HLS playlist recognition; multiple sources; source edit, refresh and delete.
- Xtream provider API: live channels, VOD catalog, series and season episodes; HLS live playback URLs.
- AVPlayer/VideoPlayer fullscreen playback for Apple-supported formats; error message for AVPlayer item failure. Unsupported containers/codecs, raw TS streams and DASH may not play. No alternative player engine.
- Favorites (long-press item), recent history for catalog items, manually configured uncompressed XMLTV programme listings (long-press live channel > guide > load). EPG requires matching tvg-id/epg_channel_id. Catalog cache may be purged by tvOS; refresh sources if necessary.
- No media or subscriptions included. Use authorized sources only.

## Not implemented / important limitations

Stalker portal, local file picker (tvOS has no conventional Files picker), automatic XMLTV discovery, compressed XMLTV guide, full timeline grid, catch-up/archive, parental PIN, shared library synchronization, TMDB, episode history/resume, advanced codec engine, custom headers, offline downloads, desktop visual parity, production app icon and Top Shelf art. Pasted text field is suitable for small playlists only. Source credentials and URLs are stored locally in UserDefaults/cache in this prototype, NOT Keychain; do not commit credentials. HTTP is permitted for legacy IPTV providers but transmits data insecurely; prefer HTTPS. Invalid TLS certificates are not bypassed.

## Validation

Core Foundation code type-checked and sample M3U/URL tests passed with Linux Swift; full app syntax parsed. The native SwiftUI target was NOT compiled with the tvOS SDK in this environment. GitHub Actions is the first hardware-target build check. No claim of successful compilation, playback or installation on a real Apple TV. If the build fails, download the `build-log` artifact (or copy the failing step output) for diagnosis.
