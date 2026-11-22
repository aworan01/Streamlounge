import SwiftUI
import AVFoundation
import AVKit
import UIKit
import Combine
import TVVLCKit

// Playback preferences remain compatible with the original catalog and bundle ID.
@MainActor final class PlaybackSession: ObservableObject {
    @Published private(set) var engine = "AVPlayer"
    @Published private(set) var status = "Select a channel."
    let native = AVPlayer()
    let vlc = VLCMediaPlayer()
    private var active: Media?
    private var monitor: Task<Void,Never>?
    private var started = Date()
    private var paused = false
    private var retried = false
    weak var layer: AVPlayerLayer?
    private var options: UserDefaults { .standard }
    func start(_ item: Media, force: String? = nil) {
        stop(); active=item; paused=false; retried=false
        let preference=force ?? options.string(forKey:"engine") ?? "Auto"
        let useVLC=preference == "VLC" || (preference == "Auto" && (item.name.localizedCaseInsensitiveContains("4K") || item.name.localizedCaseInsensitiveContains("UHD") || item.url.lowercased().contains(".mkv")))
        launch(useVLC ? "VLC" : "AVPlayer")
    }
    private func launch(_ next: String) {
        guard let current=active,let url=httpURL(current.url) else {status="Invalid stream URL";return}
        monitor?.cancel();native.pause();native.replaceCurrentItem(with:nil);vlc.stop()
        engine=next;started=Date();status="Opening with \(next)…";paused=false
        let cache=options.object(forKey:"bufferSeconds") as? Double ?? 5
        if next == "VLC" {
            let media=VLCMedia(url:url)
            media.addOption(":network-caching=\(Int(cache*1000))")
            if options.object(forKey:"hardware") != nil && !options.bool(forKey:"hardware") {media.addOption(":avcodec-hw=none")}
            vlc.media=media;vlc.play()
        } else {
            let media=AVPlayerItem(url:url);media.preferredForwardBufferDuration=cache
            native.replaceCurrentItem(with:media);native.play()
        }
        monitor=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:1_000_000_000)
                guard !Task.isCancelled,let self=self else{return};self.check()
            }
        }
    }
    private func check() {
        guard active != nil,!paused else{return}
        let elapsed=Date().timeIntervalSince(started)
        if engine == "AVPlayer" {
            guard let item=native.currentItem else{return}
            let size=item.presentationSize
            let failed=item.status == .failed
            let ready=layer?.isReadyForDisplay == true
            if (failed || (elapsed>15 && !ready)), (options.string(forKey:"engine") ?? "Auto") == "Auto", !retried {
                retried=true;launch("VLC");return
            }
            let dimension=size.width>0 ? "\(Int(size.width)) × \(Int(size.height))" : "Video size unavailable"
            let rate=item.accessLog()?.events.last?.observedBitrate ?? 0
            status=failed ? "AVPlayer error • Try VLC" : "AVPlayer • \(dimension) • \(ready ? "Video ready" : "Awaiting picture")\(rate>0 ? " • \(String(format:"%.1f",rate/1_000_000)) Mbps" : "")"
        } else {
            let size=vlc.videoSize
            status="VLC • \(size.width>0 ? "\(Int(size.width)) × \(Int(size.height))" : "Awaiting picture") • \(vlc.isPlaying ? "Playing" : "Opening / buffering")"
            // Do not repeatedly reconnect: a provider may allow only one concurrent stream.
            if elapsed>25 && size.width==0 { status += " • No video detected; try disabling hardware decoding in Settings." }
        }
    }
    func switchEngine() {guard active != nil else{return};retried=true;launch(engine == "VLC" ? "AVPlayer" : "VLC")}
    func togglePause() {guard active != nil else{return};paused.toggle();if engine == "VLC" {if paused{vlc.pause()}else{vlc.play()}}else{if paused{native.pause()}else{native.play()}};if paused{status="Paused • \(engine)"}}
    func stop(){monitor?.cancel();monitor=nil;native.pause();native.replaceCurrentItem(with:nil);vlc.stop();active=nil;status="Stopped"}
}
final class VideoHost:UIView {
    override class var layerClass:AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    let vlcView=UIView()
    override init(frame:CGRect){super.init(frame:frame);backgroundColor = .black;vlcView.backgroundColor = .black;addSubview(vlcView);playerLayer.videoGravity = .resizeAspect}
    required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
    override func layoutSubviews(){super.layoutSubviews();vlcView.frame=bounds}
}
struct PlayerSurface:UIViewRepresentable {
    @ObservedObject var session:PlaybackSession
    func makeUIView(context:Context)->VideoHost{let view=VideoHost(frame:.zero);view.vlcView.isHidden=session.engine != "VLC";view.playerLayer.player=session.native;session.layer=view.playerLayer;session.vlc.drawable=view.vlcView;return view}
    func updateUIView(_ view:VideoHost,context:Context){view.vlcView.isHidden=session.engine != "VLC";view.playerLayer.player=session.engine == "AVPlayer" ? session.native : nil;session.layer=view.playerLayer;if session.engine == "VLC" {session.vlc.drawable=view.vlcView}}
}
struct Playback:View {
    let item:Media
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session=PlaybackSession()
    var body:some View { VStack(spacing:15){PlayerSurface(session:session).frame(maxWidth:.infinity,maxHeight:.infinity);Text(item.name).font(.headline);HStack{Button("Play / Pause"){session.togglePause()};Button("Switch player"){session.switchEngine()};Button("Close"){dismiss()}}.font(.caption);Text(session.status).font(.caption2).foregroundStyle(.secondary)}.padding(30).background(Color.black.ignoresSafeArea()).onAppear{session.start(item)}.onDisappear{session.stop()}.onExitCommand{dismiss()} }
}
