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
    #if canImport(KSPlayerUI) && canImport(KSPlayer)
    let ksPlayer = KSPlayerBridge()
    #endif
    private var active: Media?
    var onProgress: ((Media,Double,Double)->Void)?
    var resumePosition: Double = 0
    private var resumed=false
    private var lastProgress=Date.distantPast
    private var monitor: Task<Void,Never>?
    private var clearKeyTask: Task<Void,Never>?
    private var started = Date()
    @Published private(set) var paused = false
    @Published private(set) var qualityCap: Double = 0
    @Published private(set) var streamBitrate: Double? = nil
    @Published private(set) var inputThroughput: Double? = nil
    private var vlcSamples: [(time: Date, bytes: Int64)] = []
    private var retried = false
    private var automatic = true
    // Keep one physical video UIView and AVPlayerLayer for the entire playback
    // session. Recreating VLC drawables during inline-to-fullscreen transitions
    // can leave audio playing while the rendered picture goes black.
    let host = VideoHost(frame:.zero)
    var layer: AVPlayerLayer { host.playerLayer }
    init() {
        host.playerLayer.player = native
        vlc.drawable = host.vlcView
    }
    func mountVideo(in container: UIView) {
        if host.superview !== container {
            host.removeFromSuperview()
            host.frame = container.bounds
            host.autoresizingMask = [.flexibleWidth,.flexibleHeight]
            container.addSubview(host)
        }
        host.frame=container.bounds
        host.vlcView.isHidden = engine != "VLC"
        host.playerLayer.player = engine == "AVPlayer" ? native : nil
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {
            if ksPlayer.view.superview !== container {
                ksPlayer.view.removeFromSuperview()
                ksPlayer.view.frame=container.bounds
                ksPlayer.view.autoresizingMask = [UIView.AutoresizingMask.flexibleWidth, UIView.AutoresizingMask.flexibleHeight]
                container.addSubview(ksPlayer.view)
            }
        } else {ksPlayer.detach()}
        #endif
        host.setNeedsLayout()
        host.layoutIfNeeded()
    }
    var videoOutputDescription:String {
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {
            let size=ksPlayer.view.bounds.size
            return "KSPlayer \(ksPlayer.view.window == nil ? "Detached" : "Attached") • \(Int(size.width)) × \(Int(size.height)) view"
        }
        #endif
        let size=host.bounds.size
        return "\(host.window == nil ? "Detached" : "Attached") • \(Int(size.width)) × \(Int(size.height)) view"
    }
    func reconnectVideoOutput() {
        if engine == "VLC" {
            vlc.drawable = nil
            vlc.drawable = host.vlcView
        } else if engine == "AVPlayer" {
            host.playerLayer.player = nil
            host.playerLayer.player = native
        }
        host.setNeedsLayout()
        host.layoutIfNeeded()
        status = "Video output reconnected • \(engine)"
    }
    private var options: UserDefaults { .standard }
    func start(_ item: Media, force: String? = nil) {
        stop(); active=item; paused=false; retried=false;resumed=false
        let encrypted = ClearKeyVault.shared.enabled(for:item.url) != nil
        let preference=force ?? (encrypted ? "KSPlayer" : (options.string(forKey:"engine") ?? "Auto"))
        let recovered=PlaybackCrashGuard.recovered(item) && !encrypted
        automatic = preference == "Auto" && !recovered
        // Prefer the system's hardware decoding for HLS UHD/HDR. VLC remains
        // an explicit choice or an automatic fallback for incompatible streams.
        let extensionHint=URL(string:item.url)?.pathExtension.lowercased() ?? ""
        let useVLC = !recovered && (preference == "VLC" || (preference == "Auto" && ["mkv","avi","ts"].contains(extensionHint)))
        if recovered {status="Previous playback stopped unexpectedly; using the native player for recovery."}
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if preference == "KSPlayer", !recovered {launch("KSPlayer");return}
        if preference == "Auto",extensionHint == "mpd" {launch("KSPlayer");return}
        #endif
        launch(useVLC ? "VLC" : "AVPlayer")
    }
    private func launch(_ next: String) {
        guard let current=active,let url=httpURL(current.url) else {status="Invalid stream URL";return}
        monitor?.cancel();clearKeyTask?.cancel();clearKeyTask=nil
        native.pause();native.replaceCurrentItem(with:nil);vlc.stop()
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" && next != "KSPlayer" {ksPlayer.close()}
        #endif
        streamBitrate=nil;inputThroughput=nil;vlcSamples.removeAll()
        engine=next;started=Date();status="Opening with \(next)…";paused=false
        PlaybackCrashGuard.mark(current.id,engine:next)
        let cache=options.object(forKey:"bufferSeconds") as? Double ?? 5
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if next == "KSPlayer" {
            if let profile = ClearKeyVault.shared.enabled(for:current.url) {
                status = "Requesting authorized ClearKey for KSPlayer…"
                clearKeyTask = Task { [weak self] in
                    do {
                        let keyHex = try await ClearKeyLicenseService.resolve(profile)
                        guard !Task.isCancelled, let self,
                              self.active?.id == current.id, self.engine == "KSPlayer" else {return}
                        self.ksPlayer.open(url,clearKeyHex:keyHex)
                        self.status="KSPlayer FFmpeg ClearKey playback requested (CENC/AES-CTR)."
                    } catch {
                        guard !Task.isCancelled, let self,
                              self.active?.id == current.id else {return}
                        self.status="ClearKey: \(error.localizedDescription)"
                    }
                }
            } else {
                ksPlayer.open(url)
                status="KSPlayer starting • Choose FFmpeg first in Settings if UHD has audio but no picture."
            }
        }
        #endif
        if next == "VLC" {
            let media=VLCMedia(url:url)
            media.addOption(":network-caching=\(Int(cache*1000))")
            if options.object(forKey:"hardware") != nil && !options.bool(forKey:"hardware") {media.addOption(":avcodec-hw=none")}
            vlc.media=media;vlc.play()
        } else if next == "AVPlayer" {
            let media=AVPlayerItem(url:url);media.preferredForwardBufferDuration=cache;media.preferredPeakBitRate=qualityCap
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
            if let original=active,original.kind != .live {sampleProgress()}
            let size=item.presentationSize
            let failed=item.status == .failed
            let ready=layer.isReadyForDisplay
            if (failed || (elapsed>15 && !ready)), automatic, !retried {
                retried=true;launch("VLC");return
            }
            let dimension=size.width>0 ? "\(Int(size.width)) × \(Int(size.height))" : "Video size unavailable"
            let event=item.accessLog()?.events.last
            let indicated=event?.indicatedBitrate ?? 0
            let rate=event?.observedBitrate ?? 0
            streamBitrate=indicated.isFinite && indicated>0 ? indicated : nil
            inputThroughput=rate.isFinite && rate>0 ? rate : nil
            status=failed ? "AVPlayer error • Try VLC" : "AVPlayer • \(dimension) • \(ready ? "Video ready" : "Awaiting picture")\(rate>0 ? " • \(String(format:"%.1f",rate/1_000_000)) Mbps" : "")"
        } else if engine == "VLC" {
            if let original=active,original.kind != .live {sampleProgress()}
            let size=vlc.videoSize
            sampleVLCBitrate()
            status="VLC • \(size.width>0 ? "\(Int(size.width)) × \(Int(size.height))" : "Awaiting picture") • \(vlc.isPlaying ? "Playing" : "Opening / buffering")"
            // Do not repeatedly reconnect: a provider may allow only one concurrent stream.
            if elapsed>25 && size.width==0 { status += " • No video detected; try disabling hardware decoding in Settings." }
        } else if engine == "KSPlayer" {
            #if canImport(KSPlayerUI) && canImport(KSPlayer)
            let size=ksPlayer.videoSize
            let decoded=size.width > 0 && size.height > 0
            status="KSPlayer • \(decoded ? "\(Int(size.width)) × \(Int(size.height))" : "Video size unavailable") • \(ksPlayer.isPlaying ? "Playing" : "Opening / buffering")"
            if elapsed>20 && !decoded {status += " • Try Settings → Playback → KS decoding → FFmpeg first, then reload."}
            #endif
        }
        if elapsed>30, let item=active,videoDimensions.width>0 {
            PlaybackCrashGuard.clearRecovery(item)
        }
    }
    // VLC's demux byte counter is measured in bytes. A rolling delta gives
    // an estimate of combined media bitrate, not a video-only encoder rate.
    private func sampleVLCBitrate() {
        guard let media=vlc.media else {streamBitrate=nil;return}
        let bytes=Int64(media.numberOfReadBytesOnDemux)
        let now=Date()
        if let last=vlcSamples.last, bytes<last.bytes {vlcSamples.removeAll();streamBitrate=nil}
        vlcSamples.append((now,bytes))
        vlcSamples.removeAll{now.timeIntervalSince($0.time)>7}
        if let first=vlcSamples.first {
            let seconds=now.timeIntervalSince(first.time)
            if seconds>=3 {
                let rate=Double(bytes-first.bytes)*8/seconds
                streamBitrate=rate.isFinite && rate>0 ? rate : nil
            }
        }
        inputThroughput=nil
    }
    private func formatRate(_ rate:Double?) -> String {
        guard let rate=rate,rate.isFinite,rate>0 else{return "Unavailable / measuring"}
        return String(format:"%.2f Mbps",rate/1_000_000)
    }
    var bitrateDescription:String {formatRate(streamBitrate)}
    var throughputDescription:String {formatRate(inputThroughput)}
    private var videoDimensions:CGSize {
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {return ksPlayer.videoSize}
        #endif
        return engine == "VLC" ? vlc.videoSize : (native.currentItem?.presentationSize ?? .zero)
    }
    var resolutionDescription:String {
        let size=videoDimensions
        return size.width>0 && size.height>0 ? "\(Int(size.width)) × \(Int(size.height))" : "Unavailable"
    }
    /// Actual decoder-reported pixel dimensions, never a fixed channel-name label.
    /// Until a frame is decoded, display — rather than incorrectly claiming 4K.
    var qualityLabel:String {
        let size=videoDimensions
        return qualityTier(width:Double(size.width),height:Double(size.height))
    }
    private func sampleProgress() {
        guard let m=active, m.kind != .live else{return}
        var time:Double=0,duration:Double=0
        if engine == "KSPlayer" { return }
        if engine == "VLC" {
            // VLCTime values are milliseconds.
            time=Double(vlc.time.intValue)/1000
            duration=Double(vlc.media?.length.intValue ?? 0)/1000
            if !resumed && resumePosition>30 && duration>0 && vlc.isPlaying {
                vlc.position=Float(min(0.94,resumePosition/duration))
                resumed=true
            }
        } else {
            time=native.currentTime().seconds
            duration=native.currentItem?.duration.seconds ?? 0
            if !resumed && resumePosition>30 && duration.isFinite && duration>0 && native.currentItem?.status == .readyToPlay {
                native.seek(to:CMTime(seconds:resumePosition,preferredTimescale:600))
                resumed=true
                return
            }
        }
        guard time.isFinite,duration.isFinite,duration>0,time>=0 else{return}
        if Date().timeIntervalSince(lastProgress)>5 {lastProgress=Date();onProgress?(m,time,duration)}
    }
    struct Track: Identifiable { let id: Int32; let name: String; let selected: Bool }
    func tracks(_ kind:String) -> [Track] {
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {
            let entries:[(name:String,selected:Bool)]
            if kind == "Audio" {entries=ksPlayer.audioTracks()}
            else if kind == "Subtitles" {entries=ksPlayer.subtitleTracks()}
            else {entries=ksPlayer.videoTracks()}
            var result=entries.enumerated().map{Track(id:Int32($0.offset),name:$0.element.name,selected:$0.element.selected)}
            if kind == "Subtitles" {result.insert(Track(id:-1,name:"Off",selected:!entries.contains(where:{$0.selected})),at:0)}
            return result
        }
        #endif
        if engine == "VLC" {
            let names: [String]; let indexes: [NSNumber]; let current: Int32
            switch kind {
            case "Subtitles": names = vlc.videoSubTitlesNames as? [String] ?? []; indexes = vlc.videoSubTitlesIndexes as? [NSNumber] ?? []; current = vlc.currentVideoSubTitleIndex
            case "Audio": names = vlc.audioTrackNames as? [String] ?? []; indexes = vlc.audioTrackIndexes as? [NSNumber] ?? []; current = vlc.currentAudioTrackIndex
            default: names = vlc.videoTrackNames as? [String] ?? []; indexes = vlc.videoTrackIndexes as? [NSNumber] ?? []; current = vlc.currentVideoTrackIndex
            }
            // A negative audio index represents Disabled. It must never be
            // offered as a preferred language selection.
            return zip(indexes,names).filter{kind == "Subtitles" || $0.0.int32Value >= 0}.map{Track(id:$0.0.int32Value,name:$0.1,selected:$0.0.int32Value == current)}
        }
        guard engine == "AVPlayer",kind != "Quality", let item=native.currentItem, let group=item.asset.mediaSelectionGroup(forMediaCharacteristic: kind == "Subtitles" ? .legible : .audible) else{return []}
        let selected=item.currentMediaSelection.selectedMediaOption(in:group)
        var result=group.options.enumerated().map{Track(id:Int32($0.offset),name:$0.element.displayName,selected:$0.element == selected)}
        if kind == "Subtitles" && group.allowsEmptySelection {result.insert(Track(id:-1,name:"Off",selected:selected == nil),at:0)}
        return result
    }
    func chooseTrack(_ kind:String,_ id:Int32) {
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {
            let selected:Bool
            if kind == "Audio" {selected=ksPlayer.selectAudio(Int(id))}
            else if kind == "Subtitles" {selected=ksPlayer.selectSubtitle(Int(id))}
            else {selected=ksPlayer.selectVideo(Int(id))}
            status=selected ? "KSPlayer track selection requested." : "This track is unavailable in KSPlayer."
            objectWillChange.send();return
        }
        #endif
        if engine == "VLC" {
            switch kind {
            case "Subtitles":vlc.currentVideoSubTitleIndex=id
            case "Audio":
                let choices = vlc.audioTrackIndexes as? [NSNumber] ?? []
                guard id >= 0,choices.contains(where:{$0.int32Value == id}) else {status="Audio track unavailable";return}
                let old=vlc.currentAudioTrackIndex
                vlc.currentAudioTrackIndex=id
                if vlc.currentAudioTrackIndex != id {
                    status="Audio track could not be selected; restored previous track."
                    if old>=0 {vlc.currentAudioTrackIndex=old}
                } else {status="Selected audio track; if silent, choose another supported track."}
            default:vlc.currentVideoTrackIndex=id
            }
        } else if engine == "AVPlayer", let item=native.currentItem,let group=item.asset.mediaSelectionGroup(forMediaCharacteristic:kind == "Subtitles" ? .legible : .audible) {
            if id == -1 && kind == "Subtitles" && group.allowsEmptySelection {item.select(nil,in:group)} else if id>=0 && group.options.indices.contains(Int(id)){item.select(group.options[Int(id)],in:group)}
        }
        objectWillChange.send()
    }
    func restoreAudio() {
        if engine == "VLC" {
            if let first=(vlc.audioTrackIndexes as? [NSNumber])?.first(where:{$0.int32Value >= 0}) {
                vlc.currentAudioTrackIndex=first.int32Value
                status="Restored the first available audio track."
            } else {status="VLC reports no available audio track; try AVPlayer."}
        } else if engine == "AVPlayer",let current=native.currentItem,
                  let group=current.asset.mediaSelectionGroup(forMediaCharacteristic:.audible) {
            if let preferred=group.defaultOption ?? group.options.first {current.select(preferred,in:group);status="Restored the default audio track."}
        } else if engine == "KSPlayer" {
            #if canImport(KSPlayerUI) && canImport(KSPlayer)
            if let first=ksPlayer.audioTracks().firstIndex(where:{$0.selected}) { _ = ksPlayer.selectAudio(first) }
            else {_ = ksPlayer.selectAudio(0)}
            status="KSPlayer default audio track requested."
            #endif
        }
        objectWillChange.send()
    }
    func setQualityCap(_ cap:Double){qualityCap=cap;native.currentItem?.preferredPeakBitRate=cap}
    var playerChoices:[String] {
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        return ["Auto","AVPlayer","VLC","KSPlayer"]
        #else
        return ["Auto","AVPlayer","VLC"]
        #endif
    }
    func chooseEngine(_ name:String){guard let item=active else{return};start(item,force:name)}
    func reload(){guard active != nil else{return};launch(engine)}
    func switchEngine() {guard active != nil else{return};retried=true;launch(engine == "VLC" ? "AVPlayer" : "VLC")}
    func togglePause() {
        guard active != nil else {return}
        paused.toggle()
        if engine == "VLC" {if paused {vlc.pause()} else {vlc.play()}}
        if engine == "AVPlayer" {if paused {native.pause()} else {native.play()}}
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {if paused {ksPlayer.pause()} else {ksPlayer.play()}}
        #endif
        status=paused ? "Paused • \(engine)" : "Playing • \(engine)"
    }
    func seekBy(_ seconds:Double) {
        guard active != nil else{return}
        if engine == "AVPlayer" {
            let t=native.currentTime().seconds
            if t.isFinite {native.seek(to:CMTime(seconds:max(0,t+seconds),preferredTimescale:600))}
        }
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        if engine == "KSPlayer" {ksPlayer.seek(by:seconds)}
        #endif
    }
    func stop(){
        if let item=active,item.kind != .live {sampleProgress()}
        monitor?.cancel();monitor=nil
        clearKeyTask?.cancel();clearKeyTask=nil
        native.pause();native.replaceCurrentItem(with:nil);vlc.stop()
        #if canImport(KSPlayerUI) && canImport(KSPlayer)
        ksPlayer.close()
        #endif
        active=nil;streamBitrate=nil;inputThroughput=nil;vlcSamples.removeAll();status="Stopped"
        PlaybackCrashGuard.clear()
    }
}
final class VideoHost:UIView {
    override var canBecomeFocused:Bool { false }
    override class var layerClass:AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    let vlcView=UIView()
    override init(frame:CGRect){super.init(frame:frame);backgroundColor = .black;vlcView.backgroundColor = .black;vlcView.isUserInteractionEnabled=false;isUserInteractionEnabled=false;addSubview(vlcView);playerLayer.videoGravity = .resizeAspect}
    required init?(coder:NSCoder){fatalError("init(coder:) unavailable")}
    override func layoutSubviews(){super.layoutSubviews();vlcView.frame=bounds}
}
// The SwiftUI inline and fullscreen containers both mount the SAME
// VideoHost. TVVLCKit keeps one stable drawable across the transition.
struct PlayerSurface:UIViewRepresentable {
    @ObservedObject var session:PlaybackSession
    func makeUIView(context:Context)->UIView {
        let container=UIView(frame:.zero)
        container.backgroundColor = .black
        container.isUserInteractionEnabled=session.engine == "KSPlayer"
        session.mountVideo(in:container)
        return container
    }
    func updateUIView(_ container:UIView,context:Context) {
        container.isUserInteractionEnabled=session.engine == "KSPlayer"
        session.mountVideo(in:container)
    }
}
// Use a custom style rather than the tvOS system focus highlight. A tiny
// wake target receives remote input without covering the video surface.
private struct WakeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
// Fullscreen keeps playback and controls separate, with explicit remote focus.
struct FullPlayer:View {
    let item:Media
    @ObservedObject var session:PlaybackSession
    @ObservedObject var library:Library
    let channels:[Media]
    let onSelect:(Media)->Void
    let onClose:()->Void
    @State private var visible=true
    @State private var panel:String?=nil
    @State private var showClearKeyEditor=false
    @State private var returnFocus="pause"
    @State private var channelSourceID=""
    @State private var channelGroup="All groups"
    @FocusState private var focus:String?
    private var sourceName:String {library.sources.first{$0.id==item.sourceID}?.name ?? "Unknown source"}
    private var alternatives:[Media] {
        [item]+library.media.filter { $0.id != item.id && $0.kind == item.kind && (($0.name.caseInsensitiveCompare(item.name) == .orderedSame) || (!item.tvg.isEmpty && $0.tvg == item.tvg)) }
    }
    // Up/Down steps are always within the current playlist, not the concatenated
    // list of every imported IPTV source.
    private var sequence:[Media] {channels.filter{$0.sourceID == item.sourceID && $0.kind == item.kind}}
    private var index:Int? {sequence.firstIndex{$0.id==item.id}}
    private var channelPlaylists:[Source] {
        library.sources.filter { source in
            channels.contains(where:{$0.sourceID == source.id && $0.kind == .live})
        }
    }
    private var channelsInPlaylist:[Media] {
        let selectedID=UUID(uuidString:channelSourceID) ?? item.sourceID
        return channels.filter{$0.sourceID == selectedID && $0.kind == .live}
    }
    private var channelGroups:[String] {
        ["All groups"] + Array(Set(channelsInPlaylist.map(\.group))).sorted()
    }
    private var visibleChannels:[Media] {
        channelsInPlaylist.filter{channelGroup == "All groups" || $0.group == channelGroup}
    }
    var body:some View {
        ZStack(alignment:.bottom) {
            Color.black.ignoresSafeArea()
            PlayerSurface(session:session).frame(maxWidth:.infinity,maxHeight:.infinity).ignoresSafeArea().allowsHitTesting(false)
            if visible {
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top){VStack(alignment:.leading,spacing:5){Text(item.name).font(.system(size:38,weight:.semibold)).lineLimit(nil).fixedSize(horizontal:false,vertical:true);Text(sourceName+"  •  "+item.group).font(.system(size:23)).foregroundStyle(.secondary)};Spacer();if item.kind == .live {Text("LIVE").font(.system(size:20,weight:.bold)).padding(10).background(Color.red.opacity(0.8),in:RoundedRectangle(cornerRadius:6))}}
                    if let p=library.currentProgramme(item) {Text(p.title).font(.system(size:23)).lineLimit(nil);if let next=library.nextProgramme(item){Text("Next: "+next.title).font(.system(size:19)).foregroundStyle(.secondary).lineLimit(1)};ProgressView(value:min(1,max(0,Date().timeIntervalSince(p.start)/max(1,p.end.timeIntervalSince(p.start))))) }
                    if item.kind != .live && session.engine != "VLC" { HStack{ control("back15","gobackward.15","−15s"){session.seekBy(-15)};control("forward15","goforward.15","+15s"){session.seekBy(15)};Spacer()} }
                    HStack(spacing:8) {
                        control("prev","backward.end.fill","Previous",enabled:index.map{$0>0} ?? false){step(-1)}
                        control("pause",session.paused ? "play.fill" : "pause.fill",session.paused ? "Play" : "Pause"){session.togglePause()}
                        control("next","forward.end.fill","Next",enabled:index.map{$0+1<sequence.count} ?? false){step(1)}
                        control("channels","list.bullet","Channels",enabled:item.kind == .live && !channelPlaylists.isEmpty){open("Channels")}
                        control("source","rectangle.2.swap","Source"){open("Source")}
                        control("favorite",library.favorites.contains(item.id) ? "star.fill" : "star","Favourite"){library.toggle(item)}
                        control("audio","speaker.wave.2","Audio"){open("Audio")}
                        control("subs","captions.bubble","Subtitles"){open("Subtitles")}
                        control("quality","tv","Quality",badge:session.qualityLabel){open("Quality")}
                        control("info","info.circle","Info"){open("Info")}
                        control("engine","gearshape","Player"){open("Player")}
                        control("hide","chevron.down","Hide"){hide()}
                        control("close","rectangle.compress.vertical","Close"){onClose()}
                    }.focusSection()
                    Text(session.status).font(.system(size:20)).foregroundStyle(.secondary).lineLimit(nil)
                }.padding(.horizontal,38).padding(.bottom,25).padding(.top,75)
                .background(LinearGradient(colors:[.clear,.black.opacity(0.9),.black],startPoint:.top,endPoint:.bottom))
                .opacity(panel == nil ? 1 : 0).disabled(panel != nil)
            } else {
                Button{show()}label:{Color.clear.frame(width:44,height:44).contentShape(Rectangle())}
                    .buttonStyle(WakeButtonStyle())
                    .focused($focus,equals:"wake")
                    .accessibilityLabel("Show playback controls")
                    .onMoveCommand{_ in show()}
                    .padding(12)
            }
            if let pane=panel {
                if pane == "Channels" {channelBrowser} else {panelView(pane)}
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.black)
        .onAppear { assignFocus("pause") }
        .onChange(of:item.id){_ in
            if panel == "Channels" {
                channelSourceID=item.sourceID.uuidString
                channelGroup=item.group
                assignFocus("channel-"+item.id)
            }
        }
        .sheet(isPresented:$showClearKeyEditor) {
            ClearKeyEditor(streamURL:item.url) { session.start(item,force:"KSPlayer") }
        }
        .onPlayPauseCommand{session.togglePause()}
        .onExitCommand{if panel != nil {closePanel()} else if visible {hide()} else {onClose()}}
    }
    private func assignFocus(_ key:String){Task{@MainActor in await Task.yield();focus=key}}
    private func show(){visible=true;assignFocus("pause")}
    private func hide(){panel=nil;visible=false;assignFocus("wake")}
    private func open(_ name:String){
        returnFocus=focus ?? "pause"
        if name == "Channels" {
            channelSourceID=item.sourceID.uuidString
            channelGroup=item.group
        }
        panel=name
        assignFocus("panelClose")
    }
    private func closePanel(){panel=nil;assignFocus(returnFocus)}
    private func step(_ delta:Int){if let i=index,sequence.indices.contains(i+delta){onSelect(sequence[i+delta])}}
    private func control(_ key:String,_ icon:String,_ title:String,enabled:Bool=true,badge:String?=nil,action:@escaping ()->Void)->some View {
        Button(action:action) {
            VStack(spacing:5) {
                Group {
                    if let badge=badge {
                        Text(badge).font(.system(size:22,weight:.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    } else {
                        Image(systemName:icon).font(.system(size:27,weight:.medium))
                    }
                }
                    .foregroundStyle(focus == key ? Color.cyan : Color.white)
                    .frame(width:56,height:48)
                    .background(RoundedRectangle(cornerRadius:9).fill(focus == key ? Color.cyan.opacity(0.18) : Color.black.opacity(0.32)))
                    .overlay(RoundedRectangle(cornerRadius:9).strokeBorder(focus == key ? Color.cyan : Color.white.opacity(0.12),lineWidth:2))
                Text(title).font(.system(size:17,weight:.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(focus == key ? Color.cyan : Color.white.opacity(0.9))
            }
            .frame(maxWidth:.infinity).frame(height:78).contentShape(Rectangle())
        }.buttonStyle(ManualFocusStyle()).focused($focus,equals:key).disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
    private func option(_ key:String,_ title:String,chosen:Bool=false,action:@escaping ()->Void)->some View {
        Button(action:action) {
            HStack(spacing:10) {
                Capsule().fill(focus == key ? Color.cyan : Color.clear).frame(width:3,height:24)
                Text(title).font(.system(size:23)).lineLimit(nil).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:4)
                if chosen { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color.cyan) }
            }.padding(.horizontal,10).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
                .foregroundStyle(focus == key ? Color.cyan : Color.white)
                .background(RoundedRectangle(cornerRadius:8).fill(focus == key ? Color.cyan.opacity(0.12) : Color.white.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(focus == key ? Color.cyan.opacity(0.85) : Color.clear,lineWidth:1.5))
        }.buttonStyle(ManualFocusStyle()).focused($focus,equals:key)
    }

    /// Two-column channel browser. Initial scroll/focus tracks the actual playing
    /// item, with playlist and group choices accessible from the left column.
    private var channelBrowser:some View {
        HStack {
            Spacer(minLength:0)
            VStack(alignment:.leading,spacing:14) {
                HStack {
                    Text("Channels").font(.system(size:36,weight:.bold))
                    Spacer()
                    option("panelClose","Back to video controls"){closePanel()}
                        .frame(width:290)
                }
                HStack(alignment:.top,spacing:16) {
                    VStack(alignment:.leading,spacing:9) {
                        Text("Playlists").font(.system(size:21,weight:.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:5) {
                                ForEach(channelPlaylists){source in
                                    option("playlist-"+source.id.uuidString,source.name,chosen:source.id.uuidString == channelSourceID) {
                                        channelSourceID=source.id.uuidString
                                        channelGroup="All groups"
                                    }
                                }
                            }
                        }.frame(maxHeight:200)
                        Text("Groups").font(.system(size:21,weight:.semibold)).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVStack(alignment:.leading,spacing:5) {
                                ForEach(channelGroups,id:\.self){group in
                                    option("group-"+group,group,chosen:channelGroup == group) {
                                        channelGroup=group
                                    }
                                }
                            }
                        }
                    }.frame(width:290).focusSection()
                    VStack(alignment:.leading,spacing:9) {
                        Text("\(visibleChannels.count) channels • \(channelGroup)")
                            .font(.system(size:20)).foregroundStyle(.secondary)
                            .lineLimit(2)
                        ScrollViewReader {proxy in
                            ScrollView {
                                LazyVStack(alignment:.leading,spacing:6) {
                                    ForEach(visibleChannels){channel in
                                        option("channel-"+channel.id,channel.name,chosen:channel.id == item.id) {
                                            onSelect(channel)
                                            closePanel()
                                        }
                                        .id(channel.id)
                                    }
                                }
                            }
                            .onAppear {
                                Task { @MainActor in
                                    await Task.yield()
                                    if visibleChannels.contains(where:{$0.id == item.id}) {
                                        proxy.scrollTo(item.id,anchor:.center)
                                        focus="channel-"+item.id
                                    } else if let first=visibleChannels.first {
                                        proxy.scrollTo(first.id,anchor:.top)
                                    }
                                }
                            }
                            .onChange(of:channelGroup){_ in
                                if let first=visibleChannels.first {
                                    proxy.scrollTo(first.id,anchor:.top)
                                }
                            }
                            .onChange(of:channelSourceID){_ in
                                if let first=visibleChannels.first {
                                    proxy.scrollTo(first.id,anchor:.top)
                                }
                            }
                        }
                    }.frame(maxWidth:.infinity).focusSection()
                }.frame(maxHeight:.infinity)
            }
            .padding(30)
            .frame(width:1060)
            .frame(maxHeight:.infinity,alignment:.topLeading)
            .background(Color(red:0.08,green:0.10,blue:0.15))
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }

    private func panelView(_ name:String)->some View {
        HStack {Spacer();VStack(alignment:.leading,spacing:14){
            Text(name).font(.system(size:36,weight:.bold))
            option("panelClose","Back to controls"){closePanel()}
            ScrollView {LazyVStack(alignment:.leading,spacing:8){
                switch name {
                case "Source":
                    if alternatives.count == 1 {Text("No matching alternative source in imported playlists.").font(.system(size:22)).foregroundStyle(.secondary)}
                    ForEach(alternatives){m in option("source-"+m.id,(library.sources.first{$0.id==m.sourceID}?.name ?? "Source")+" — "+m.name,chosen:m.id==item.id){if m.id != item.id {onSelect(m)};closePanel()}}
                case "Audio","Subtitles":
                    if name == "Audio" {option("restoreAudio","Restore default sound"){session.restoreAudio()}}
                    let tracks=session.tracks(name)
                    if tracks.isEmpty {Text("No selectable tracks reported by this player.").font(.system(size:22)).foregroundStyle(.secondary)}
                    ForEach(tracks){t in option("track-"+String(t.id),t.name,chosen:t.selected){session.chooseTrack(name,t.id)}}
                case "Quality":
                    Text("Detected quality: "+session.qualityLabel+" • "+session.resolutionDescription).font(.system(size:22)).foregroundStyle(.secondary)
                    Text(session.status).font(.system(size:20)).foregroundStyle(.secondary)
                    if session.engine == "AVPlayer" {
                        Text("Adaptive stream bitrate limit (not a fixed resolution). Original removes the cap.").font(.system(size:20)).foregroundStyle(.secondary)
                        ForEach([0.0,3_000_000,6_000_000,12_000_000,25_000_000],id:\.self){cap in option("cap-"+String(cap),cap==0 ? "Original / Auto" : "Up to \(Int(cap/1_000_000)) Mbps",chosen:session.qualityCap==cap){session.setQualityCap(cap)}}
                    } else {
                        Text("Available decoded video tracks, not adaptive HLS variants. The active engine chooses quality automatically unless separate tracks are exposed.").font(.system(size:20)).foregroundStyle(.secondary)
                        ForEach(session.tracks("Quality")){t in option("video-"+String(t.id),t.name,chosen:t.selected){session.chooseTrack("Quality",t.id)}}
                    }
                case "Player":
                    ForEach(session.playerChoices,id:\.self){engine in option("engine-"+engine,engine,chosen:session.engine==engine){session.chooseEngine(engine)}}
                    option("videoOutput","Reconnect video output"){session.reconnectVideoOutput()}
                    option("reload","Reload stream"){session.reload()}
                    option("clearKey","ClearKey keys / license server") {
                        closePanel();showClearKeyEditor=true
                    }
                    if session.engine == "KSPlayer" {Text("KSPlayer's video and audio tracks are selectable from the Stream Lounge controls. For UHD without a picture, select FFmpeg first in Settings and reopen the stream.").font(.caption).foregroundStyle(.secondary)}
                default:
                    Text(item.name).font(.system(size:27,weight:.semibold));Text("Playlist: "+sourceName);Text("Category: "+item.group);Text("Engine: "+session.engine)
                    Text("Video quality: "+session.qualityLabel)
                    Text("Resolution: "+session.resolutionDescription)
                    Text("Video surface: "+session.videoOutputDescription)
                    if PlaybackCrashGuard.recovered(item) {Text("Recovery mode: a previous playback session stopped unexpectedly. Try AVPlayer first.").foregroundStyle(.yellow)}
                    Text((session.engine == "VLC" ? "Bitrate (estimated): " : "Stream bitrate: ")+session.bitrateDescription)
                    if session.engine == "AVPlayer" {Text("Download throughput: "+session.throughputDescription)}
                    Text(session.status);if let host=httpURL(item.url)?.host {Text("Server: "+host)}
                }
            }.frame(maxWidth:.infinity,alignment:.leading)}
        }.padding(32).frame(width:670).frame(maxHeight:.infinity,alignment:.topLeading).background(Color(red:0.08,green:0.10,blue:0.15)).focusSection()}.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
struct Playback:View {
    let item:Media
    @ObservedObject var library:Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session=PlaybackSession()
    @State private var current:Media?
    var body:some View {
        FullPlayer(item:current ?? item,session:session,library:library,channels:library.media.filter{$0.kind == item.kind},onSelect:{m in current=m;library.watched(m);session.resumePosition=playbackResumeTime(library.bookmark(for:m));session.start(m)},onClose:{dismiss()})
            .onAppear{
                session.onProgress={media,time,duration in library.record(media,seconds:time,duration:duration)}
                session.resumePosition=playbackResumeTime(library.bookmark(for:item))
                session.start(item)
            }.onDisappear{session.stop()}
    }
}
