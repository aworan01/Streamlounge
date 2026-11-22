# Stream Lounge TV v0.3.6 — native feed / ClearKey diagnostics

**Watched connection:** A dedicated Watched screen references `https://watched.cx/home` but does not embed or scrape the website. A provider-authorized native M3U feed URL can be added through the screen; content is played with the existing tvOS engines. The site's private authentication, catalog, and Cloudflare challenge cannot be reproduced or bypassed without a supported provider API and authorization. Entering the website homepage as a playlist will be rejected.

**ClearKey:** ClearKey playback remains unverified on a real encrypted stream. The previously uploaded sample has a **17-byte** content key (AES-128 requires 16 bytes); the M3U importer now reports key and KID byte lengths, and playback explicitly reports when no valid key was imported. The app does not auto-correct keys or extract them. Currently only single-key CENC on supported DASH/MP4 through KSPlayer FFmpeg is within scope. ClearKey-labelled HLS is reported as unsupported instead of silently failing. W3C license server connectivity and encrypted playback require a real authorized fixture. The error remains visible in the player.

**Build:** Keep Xcode 26.2 and KSPlayer 5.6.2; use the established GitHub Actions `build-tvos.yml`. Preserve bundle ID and source/playlist data when installing.

---

## v0.3.5 — SwiftUI Settings selection compiler hotfix

- Fixes the Xcode 26.2 compilation failure at `ConfirmSelection.swift:27:25` ("compiler unable to type-check this expression in reasonable time").
- Breaks the large generic SwiftUI view expression into separate summary, panel, and choice-row views. **This is a compiler-performance refactor, not a change to preference storage.**
- Preserves visible cyan focus highlighting; the committed choice retains a checkmark, while moving the Siri Remote focus **does not modify** the setting.
- Press Select to commit, or Back/Cancel to leave the prior setting unchanged.
- Retains KSPlayer, M3U protection metadata and all v0.3.4 functionality.
- Swift syntax and platform-independent regression tests have been run; a full Xcode/tvOS build is still required.

## v0.3.4 — Playlist ClearKey / KS rendering / Focus fix

- M3U parser now retains `#KODIPROP` manifest/DRM metadata and `#EXTVLCOPT` user-agent/referrer per channel.
- Authorized embedded ClearKey `kid` plus `k` (standard JWK) or `h` (nonstandard playlist variant) are parsed and copied into tvOS Keychain. Key bytes are not serialized to media-cache JSON.
- Existing user-edited Keychain entries are preserved. Re-import or refresh an existing M3U for embedded keys to be recognized.
- `com.widevine.alpha` is explicitly reported as unsupported; HLS ClearKey is NOT guaranteed without knowing its encryption scheme.
- KSPlayer uses `KSPlayerLayer.makeUIView()` alone, without its built-in playback controls. Stream Lounge's fullscreen toolbar is the only controller.
- Theme and engine options show committed selection and tvOS native focus feedback. Focus traversal does not commit settings.
- ClearKey decoding remains experimental for DASH: FFmpeg version/demuxer and stream encryption scheme determine whether `cenc_decryption_key` works. No device test has been performed.
- Playlist files imported to cache are still local files and may contain provider credentials. Do not post real playlists to public GitHub repositories.

# Stream Lounge TV 0.3.3 — Confirm-to-change settings

Stream Lounge TV is an independent Apple TV IPTV application inspired by selected features of IPTVnator. It is **not** an official IPTVnator release and does not provide subscriptions, channels, playlists, DRM keys, or access to content.

## v0.3.3 — Important Siri Remote focus correction

All settings that previously used SwiftUI `Picker` controls now use a dedicated **press-to-confirm** selector. **Up/Down/Left/Right move focus only**; values are saved **only when you press the Siri Remote Select button** on an option. Back/Cancel closes a choice list without changing any setting. The current saved option is identified with a checkmark separately from the currently highlighted option.

This covers player engine, KSPlayer decoder, buffering, theme, text size, startup page, EPG source order, EPG refresh, retention and time correction, ClearKey key source, source selection in browsing and playlist source type. Existing `@AppStorage` values are preserved. Toggles still require Select to change; their focus behavior was not modified. The video player toolbar also retains its explicit button-activation actions.

To update from v0.3.2, **replace `App.swift`, `Settings.swift`, `ClearKey.swift`, `project.yml`, `README.md` and add `ConfirmSelection.swift`**. Keep the rest of the existing files and the GitHub workflow unchanged.

This is a source patch verified by Swift syntax parsing on Linux. The resulting tvOS IPA and Siri Remote operation are **not yet verified** on Apple TV.

## What's new

- **Name imported M3U playlists:** Open **Playlists → Import M3U from phone/computer**. The browser page now contains a Playlist Name field (pre-filled from the file name). The name is passed with the PIN-protected import request and becomes the actual playlist name in Live TV and Playlists. Existing source names can still be changed using Edit.
- **Exit button:** At the bottom of the application sidebar, choose **Exit** to stop playback, stop local import transfer, and return to Dashboard. Apple's public tvOS APIs do not permit an app to force-quit itself; use the TV/Home button on the Siri Remote to leave the application.
- **ClearKey options:** **Now Playing → Player → ClearKey keys / license server**, or **Settings → ClearKey**. Configure a **single key** (16-byte AES key in 32 hex characters; optional 16-byte hex KID), or an HTTPS **W3C ClearKey license server** accepting JSON POST and returning JWKS. Each configuration is associated with one exact stream URL. Saved profiles are stored in the device Keychain; fetched response keys are only kept in memory. This test path sends the key to KSPlayer's FFmpeg demuxer as `cenc_decryption_key` for DASH MPD or `decryption_key` for MP4.
- **KSPlayer in standard build:** The single **Build tvOS IPA** workflow uses Xcode 26.2 and includes KSPlayer 5.6.2 together with TVVLCKit and AVPlayer. In **Settings → Playback → Player engine**, choose Auto, AVPlayer, VLC, or **KSPlayer**. The previously separate experimental KSPlayer workflow is no longer needed. Automatic mode selects KSPlayer for MPD streams, AVPlayer for supported HLS and VLC as previously used for selected containers or fallback.

## ClearKey limitations (important)

ClearKey support is an **unverified, single-key CENC AES-CTR playback path**. It may work for compatible MP4 or MPEG-DASH streams with the FFmpeg demuxer included by KSPlayer 5.6.2. It does **not** establish interoperability with every ClearKey/DRM service or encrypted stream. It does not implement a general CDM, multi-key/rotating-key sessions, Widevine, PlayReady, FairPlay license exchange, provider-specific authentication, arbitrary AES-128 HLS key URLs, or credential/key discovery. When a stream is protected by another DRM system, switch to a provider-authorized supported delivery format or player. No test was performed using a real protected stream or licensed server.

For direct key mode provide the 16-byte key as 32 hexadecimal characters. For server mode provide the exact 16-byte KID as 32 hexadecimal characters and an **HTTPS** ClearKey license URL. The server should accept:

```json
{"kids":["base64url-encoded-16-byte-kid"],"type":"temporary"}
```

and return a standard W3C JWKS `keys` array with an `oct` key matching that KID. The application validates the match, never logs raw keys, and does not ship any keys or stream URLs. Use only keys and services you have permission to use.

## Build on GitHub website

1. Extract the complete ZIP. Upload its **contents** (not the ZIP itself) to your repository root, preserving `Assets.xcassets/` and `.github/workflows/` directory structures. Keep the bundle identifier `com.streamlounge.tv` to retain local app data when updating.
2. **Replace** `project.yml`, `.github/workflows/build-tvos.yml`, and changed Swift sources, and add `ClearKey.swift`. Upload the included `Assets.xcassets` as well if your icon is missing.
3. **Delete** the obsolete `project.ksplayer.yml` and `.github/workflows/build-tvos-ks-experimental.yml` from the repository. These are not needed in the unified build.
4. Open **Actions → Build tvOS IPA → Run workflow**. It selects GitHub macOS 26 / Xcode 26.2, resolves KSPlayer 5.6.2, installs TVVLCKit through CocoaPods, runs a ClearKey parser smoke test, builds ARM64 AppleTVOS Release, verifies the app icon, and packages an **unsigned IPA** under the artifact `StreamLoungeTV-unsigned`.
5. Download the Actions artifact, then sign/sideload using your existing Apple TV workflow. The GitHub build does not sign or install the IPA for you.

The application stores the main local catalog and imported M3U files in tvOS `Library/Caches`, which tvOS may purge. Re-import files if removed. Use LAN import only over a trusted private network: its HTTP upload is protected by the temporary six-digit PIN **but not encrypted**.

## Validation and release status

- Swift source parser: passed on Linux Swift 6.2.1.
- Cross-platform `Models.swift`/`ViewingData.swift` type-check and ClearKey key/JWKS smoke tests: passed.
- YAML parsing and archive CRC verification: passed.
- **Not verified:** Xcode compilation/linking on the tvOS SDK; actual ClearKey decoding or license-server operation on Apple TV; KSPlayer/VLC 4K/HDR rendering; physical Siri Remote controls and focus.

Do **not** interpret presence of ClearKey settings as proof that an encrypted stream will play. For failures, save and share the **build log** (without any real keys, login tokens or playlist credentials) and note whether the stream is HLS, MPD/DASH, MPEG-TS or MP4.

## Licensing

- KSPlayer 5.6.2: GPL-3.0 (see `COPYING-GPL-3.0.txt` and its upstream repository). Distribution of a combined build requires compliance with its copyleft terms, including provision of corresponding source code, alongside other dependencies' licences.
- TVVLCKit 3.7.3: LGPL-2.1.
- Parts adapted from IPTVnator v0.25.0: MIT, copyright 2019–2026 4gray (see `LICENSE.md`). IPTVnator's name and logo are trademarks of their owner and are not used as the product identity here.
- User-supplied TV artwork may have its own licensing conditions; check usage rights before redistribution.
