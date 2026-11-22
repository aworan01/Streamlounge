# KSPlayer 5.6.2 tvOS compiler hotfix and app icon

This patch corrects the errors in `build-log-ks(1).zip`:

- `KSPlayerBridge.swift` now instantiates `VideoPlayerView`, not `IOSVideoPlayerView` (the latter needs CallKit and is omitted on tvOS).
- Calls the public 5.6.2 `set(url:options:)` API with `KSOptions()` and then calls `play()`.
- Properly pauses and resets the KSPlayer session when closing.
- `Playback.swift` explicitly types the view autoresizing flags.
- Includes the supplied retro TV artwork as a layered tvOS app icon (`Assets.xcassets/AppIcon.brandassets`) and updates both XcodeGen YAML project files to compile it.

Upload these paths to the existing repository, **preserving their exact directory structure**:

```
KSPlayerBridge.swift
Playback.swift
project.yml
project.ksplayer.yml
Assets.xcassets/...
```

No changes to `.github/workflows/build-tvos-ks-experimental.yml` or `Podfile` are needed for these compiler errors.

After uploading, run **Actions → Build KSPlayer tvOS IPA (experimental) → Run workflow**.

The original file `icons8-media-64.png` was supplied as an icon reference; its transparent media/TV illustration is embedded in the asset catalog. The 64 px source is enlarged and may appear soft on a 4K display. A higher-resolution original would improve sharpness.

**Validation:** Python ZIP/PNG/asset JSON checks and Swift syntax parsing on Linux only. Xcode tvOS compilation is not available here; this needs another GitHub Actions build. Additional compiler errors could appear after the current six are cleared.
