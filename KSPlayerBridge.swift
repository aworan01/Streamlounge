import UIKit

#if canImport(KSPlayer)
import KSPlayer

// Keep all Siri Remote actions in the application's SwiftUI Now Playing bar.
// KSPlayer's UIKit toolbar does not participate reliably in our tvOS focus tree.
@MainActor final class KSPlayerBridge: KSPlayerLayerDelegate {
    private(set) var lastFailure: String? = nil
    // Render just the KSPlayer layer: no native KSPlayer toolbar, no competing
    // Siri Remote focus tree. Stream Lounge TV owns all playback controls.
    private(set) var view = UIView(frame:.zero)
    private var layer: KSPlayerLayer?
    init() {configureView()}
    private func configureView() {
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
    }

    func open(_ url: URL, clearKeyHex: String? = nil, userAgent: String? = nil, referer: String? = nil) {
        close()
        lastFailure=nil
        // In 5.6.2, secondPlayerType alone does NOT force FFmpeg. Expose a
        // separate FFmpeg-first choice for troublesome MPEG-TS/HEVC streams.
        let decoder = UserDefaults.standard.string(forKey:"ksDecoder") ?? "Native first"
        // ClearKey CENC requires FFmpeg's input demuxer. Both DASH and MOV
        // support cenc_decryption_key for single-key AES-CTR when built with
        // that demuxer; this is not a general DRM/CDM implementation.
        let encrypted = clearKeyHex != nil
        KSOptions.firstPlayerType = (encrypted || decoder == "FFmpeg first") ? KSMEPlayer.self : KSAVPlayer.self
        KSOptions.secondPlayerType = encrypted ? nil : KSMEPlayer.self
        let playbackOptions = KSOptions()
        if let key = clearKeyHex {
            let optionName = url.pathExtension.lowercased() == "mpd" ? "cenc_decryption_key" : "decryption_key"
            playbackOptions.formatContextOptions[optionName] = key
        }
        if let userAgent, !userAgent.isEmpty { playbackOptions.userAgent = userAgent }
        if let referer, !referer.isEmpty { playbackOptions.referer = referer }
        let playerLayer = KSPlayerLayer(url:url, options:playbackOptions, delegate:self)
        layer=playerLayer
        let picture=playerLayer.makeUIView()
        picture.backgroundColor = .black
        picture.isUserInteractionEnabled = false
        picture.frame=view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(picture)
        playerLayer.play()
    }

    var isPlaying:Bool {layer?.state.isPlaying ?? false}
    var videoSize:CGSize {
        layer?.player.tracks(mediaType:.video).first(where:{$0.isEnabled})?.naturalSize ?? .zero
    }
    func play() {layer?.play()}
    func pause() {layer?.pause()}
    func seek(by seconds:Double) {
        guard let player=layer?.player else {return}
        let current=player.currentPlaybackTime
        if current.isFinite {layer?.seek(time:max(0,current+seconds))}
    }
    // Positional indices are generated afresh every time the menu opens;
    // we never persist a track index between channels or engine changes.
    func audioTracks()->[(name:String,selected:Bool)] {
        (layer?.player.tracks(mediaType:.audio) ?? []).map{($0.name,$0.isEnabled)}
    }
    func videoTracks()->[(name:String,selected:Bool)] {
        (layer?.player.tracks(mediaType:.video) ?? []).map{
            ("\($0.name) • \(Int($0.naturalSize.width))×\(Int($0.naturalSize.height))",$0.isEnabled)
        }
    }
    func subtitleTracks()->[(name:String,selected:Bool)] {
        guard let model=layer?.subtitleModel else {return []}
        return model.subtitleInfos.map{($0.name,model.selectedSubtitleInfo?.name == $0.name)}
    }
    // KSPlayer 5.6.2 exposes tracks as [any MediaPlayerTrack], while
    // select(track:) requires a concrete conforming type. Explicitly dispatch
    // the three track types exported by its tvOS Swift interface instead of
    // passing an existential to the opaque/generic selection method.
    private func selectConcreteTrack(_ track: any MediaPlayerTrack, on player: any MediaPlayerProtocol) -> Bool {
        if let concrete = track as? AVMediaPlayerTrack {
            player.select(track: concrete)
        } else if let concrete = track as? AVMediaSelectionTrack {
            player.select(track: concrete)
        } else if let concrete = track as? FFmpegAssetTrack {
            player.select(track: concrete)
        } else {
            return false
        }
        return true
    }

    @discardableResult func selectAudio(_ index:Int)->Bool {
        guard let player=layer?.player else {return false}
        let tracks=player.tracks(mediaType:.audio)
        guard tracks.indices.contains(index) else {return false}
        return selectConcreteTrack(tracks[index], on: player)
    }
    @discardableResult func selectVideo(_ index:Int)->Bool {
        guard let player=layer?.player else {return false}
        let tracks=player.tracks(mediaType:.video)
        guard tracks.indices.contains(index) else {return false}
        return selectConcreteTrack(tracks[index], on: player)
    }
    @discardableResult func selectSubtitle(_ index:Int)->Bool {
        guard let layer=layer else {return false}
        let tracks=layer.subtitleModel.subtitleInfos
        if index == -1 {layer.select(subtitleInfo:nil);return true}
        guard tracks.indices.contains(index) else {return false}
        layer.select(subtitleInfo:tracks[index]);return true
    }
    func player(layer: KSPlayerLayer, state: KSPlayerState) {}
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {}
    func player(layer: KSPlayerLayer, finish error: Error?) {
        lastFailure=error?.localizedDescription
    }
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
    func detach() {view.removeFromSuperview()}
    func close() {
        layer?.stop()
        layer=nil
        view.subviews.forEach{$0.removeFromSuperview()}
        // Keep our host view mounted while replacing streams; PlayerSurface
        // reuses this view between inline and fullscreen layouts.
    }
}
#endif
