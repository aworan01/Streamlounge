import UIKit

#if canImport(KSPlayer) && canImport(KSPlayerUI)
import KSPlayer
import KSPlayerUI

// Keep all Siri Remote actions in the application's SwiftUI Now Playing bar.
// KSPlayer's UIKit toolbar does not participate reliably in our tvOS focus tree.
@MainActor final class KSPlayerBridge {
    private(set) var view = VideoPlayerView(frame: .zero)

    init() { configureView() }

    private func configureView() {
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.isMaskShow = false
    }

    func open(_ url: URL, clearKeyHex: String? = nil) {
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
        view.set(url:url,options:playbackOptions)
        view.play()
        view.isMaskShow = false
    }

    var isPlaying:Bool {view.playerLayer?.state.isPlaying ?? false}
    var videoSize:CGSize {
        view.playerLayer?.player.tracks(mediaType:.video).first(where:{$0.isEnabled})?.naturalSize ?? .zero
    }
    func play() {view.play()}
    func pause() {view.pause()}
    func seek(by seconds:Double) {
        guard let player=view.playerLayer?.player else {return}
        let current=player.currentPlaybackTime
        if current.isFinite {view.seek(time:max(0,current+seconds))}
    }
    // Positional indices are generated afresh every time the menu opens;
    // we never persist a track index between channels or engine changes.
    func audioTracks()->[(name:String,selected:Bool)] {
        (view.playerLayer?.player.tracks(mediaType:.audio) ?? []).map{($0.name,$0.isEnabled)}
    }
    func videoTracks()->[(name:String,selected:Bool)] {
        (view.playerLayer?.player.tracks(mediaType:.video) ?? []).map{
            ("\($0.name) • \(Int($0.naturalSize.width))×\(Int($0.naturalSize.height))",$0.isEnabled)
        }
    }
    func subtitleTracks()->[(name:String,selected:Bool)] {
        guard let model=view.playerLayer?.subtitleModel else {return []}
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
        guard let player=view.playerLayer?.player else {return false}
        let tracks=player.tracks(mediaType:.audio)
        guard tracks.indices.contains(index) else {return false}
        return selectConcreteTrack(tracks[index], on: player)
    }
    @discardableResult func selectVideo(_ index:Int)->Bool {
        guard let player=view.playerLayer?.player else {return false}
        let tracks=player.tracks(mediaType:.video)
        guard tracks.indices.contains(index) else {return false}
        return selectConcreteTrack(tracks[index], on: player)
    }
    @discardableResult func selectSubtitle(_ index:Int)->Bool {
        guard let layer=view.playerLayer else {return false}
        let tracks=layer.subtitleModel.subtitleInfos
        if index == -1 {layer.select(subtitleInfo:nil);return true}
        guard tracks.indices.contains(index) else {return false}
        layer.select(subtitleInfo:tracks[index]);return true
    }
    func detach() {view.removeFromSuperview()}
    func close() {
        view.pause()
        view.resetPlayer()
        view.removeFromSuperview()
        view=VideoPlayerView(frame:.zero)
        configureView()
    }
}
#endif
