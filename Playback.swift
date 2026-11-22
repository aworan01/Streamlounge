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
    @Published private(set) var paused = false
    @Published private(set) var qualityCap: Double = 0
    private var retried = false
    private var automatic = true
    weak var layer: AVPlayerLayer?
    private var options: UserDefaults { .standard }
    func start(_ item: Media, force: String? = nil) {
        stop(); active=item; paused=false; retried=false
        let preference=force ?? options.string(forKey:"engine") ?? "Auto"
        automatic = preference == "Auto"
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
            let size=item.presentationSize
            let failed=item.status == .failed
            let ready=layer?.isReadyForDisplay == true
            if (failed || (elapsed>15 && !ready)), automatic, !retried {
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
    struct Track: Identifiable { let id: Int32; let name: String; let selected: Bool }
    func tracks(_ kind:String) -> [Track] {
        if engine == "VLC" {
            let names: [String]; let indexes: [NSNumber]; let current: Int32
            switch kind {
            case "Subtitles": names = vlc.videoSubTitlesNames as? [String] ?? []; indexes = vlc.videoSubTitlesIndexes as? [NSNumber] ?? []; current = vlc.currentVideoSubTitleIndex
            case "Audio": names = vlc.audioTrackNames as? [String] ?? []; indexes = vlc.audioTrackIndexes as? [NSNumber] ?? []; current = vlc.currentAudioTrackIndex
            default: names = vlc.videoTrackNames as? [String] ?? []; indexes = vlc.videoTrackIndexes as? [NSNumber] ?? []; current = vlc.currentVideoTrackIndex
            }
            return zip(indexes,names).filter{kind == "Subtitles" || $0.0.int32Value >= 0}.map{Track(id:$0.0.int32Value,name:$0.1,selected:$0.0.int32Value == current)}
        }
        guard kind != "Quality", let item=native.currentItem, let group=item.asset.mediaSelectionGroup(forMediaCharacteristic: kind == "Subtitles" ? .legible : .audible) else{return []}
        let selected=item.currentMediaSelection.selectedMediaOption(in:group)
        var result=group.options.enumerated().map{Track(id:Int32($0.offset),name:$0.element.displayName,selected:$0.element == selected)}
        if group.allowsEmptySelection {result.insert(Track(id:-1,name:"Off",selected:selected == nil),at:0)}
        return result
    }
    func chooseTrack(_ kind:String,_ id:Int32) {
        if engine == "VLC" {
            switch kind {case "Subtitles":vlc.currentVideoSubTitleIndex=id;case "Audio":vlc.currentAudioTrackIndex=id;default:vlc.currentVideoTrackIndex=id}
        } else if let item=native.currentItem,let group=item.asset.mediaSelectionGroup(forMediaCharacteristic:kind == "Subtitles" ? .legible : .audible) {
            if id == -1 && group.allowsEmptySelection {item.select(nil,in:group)} else if group.options.indices.contains(Int(id)){item.select(group.options[Int(id)],in:group)}
        }
        objectWillChange.send()
    }
    func setQualityCap(_ cap:Double){qualityCap=cap;native.currentItem?.preferredPeakBitRate=cap}
    func chooseEngine(_ name:String){guard let item=active else{return};start(item,force:name)}
    func reload(){guard active != nil else{return};launch(engine)}
    func switchEngine() {guard active != nil else{return};retried=true;launch(engine == "VLC" ? "AVPlayer" : "VLC")}
    func togglePause() {guard active != nil else{return};paused.toggle();if engine == "VLC" {if paused{vlc.pause()}else{vlc.play()}}else{if paused{native.pause()}else{native.play()}};if paused{status="Paused • \(engine)"}}
    func stop(){monitor?.cancel();monitor=nil;native.pause();native.replaceCurrentItem(with:nil);vlc.stop();active=nil;status="Stopped"}
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
struct PlayerSurface:UIViewRepresentable {
    @ObservedObject var session:PlaybackSession
    func makeUIView(context:Context)->VideoHost{let view=VideoHost(frame:.zero);view.vlcView.isHidden=session.engine != "VLC";view.playerLayer.player=session.native;session.layer=view.playerLayer;session.vlc.drawable=view.vlcView;return view}
    func updateUIView(_ view:VideoHost,context:Context){view.vlcView.isHidden=session.engine != "VLC";view.playerLayer.player=session.engine == "AVPlayer" ? session.native : nil;session.layer=view.playerLayer;if session.engine == "VLC", (session.vlc.drawable as? UIView) !== view.vlcView {session.vlc.drawable=view.vlcView}}
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
    @FocusState private var focus:String?
    private var sourceName:String {library.sources.first{$0.id==item.sourceID}?.name ?? "Unknown source"}
    private var alternatives:[Media] {
        [item]+library.media.filter { $0.id != item.id && $0.kind == item.kind && (($0.name.caseInsensitiveCompare(item.name) == .orderedSame) || (!item.tvg.isEmpty && $0.tvg == item.tvg)) }
    }
    private var index:Int? {channels.firstIndex{$0.id==item.id}}
    var body:some View {
        ZStack(alignment:.bottom) {
            Color.black.ignoresSafeArea()
            PlayerSurface(session:session).frame(maxWidth:.infinity,maxHeight:.infinity).ignoresSafeArea().allowsHitTesting(false)
            if visible {
                VStack(alignment:.leading,spacing:10) {
                    HStack(alignment:.top){VStack(alignment:.leading,spacing:5){Text(item.name).font(.system(size:38,weight:.semibold)).lineLimit(nil).fixedSize(horizontal:false,vertical:true);Text(sourceName+"  •  "+item.group).font(.system(size:23)).foregroundStyle(.secondary)};Spacer();if item.kind == .live {Text("LIVE").font(.system(size:20,weight:.bold)).padding(10).background(Color.red.opacity(0.8),in:RoundedRectangle(cornerRadius:6))}}
                    if let p=library.guide.first(where:{library.guideSource==item.sourceID && $0.channel==item.tvg && $0.start<=Date() && $0.end>Date()}) {Text(p.title).font(.system(size:23)).lineLimit(nil);ProgressView(value:min(1,max(0,Date().timeIntervalSince(p.start)/max(1,p.end.timeIntervalSince(p.start))))) }
                    if item.kind != .live && session.engine == "AVPlayer" { HStack{ control("back15","gobackward.15","−15s"){seek(-15)};control("forward15","goforward.15","+15s"){seek(15)};Spacer()} }
                    HStack(spacing:8) {
                        control("prev","backward.end.fill","Previous",enabled:index.map{$0>0} ?? false){step(-1)}
                        control("pause",session.paused ? "play.fill" : "pause.fill",session.paused ? "Play" : "Pause"){session.togglePause()}
                        control("next","forward.end.fill","Next",enabled:index.map{$0+1<channels.count} ?? false){step(1)}
                        control("channels","list.bullet","Channels",enabled:!channels.isEmpty){open("Channels")}
                        control("source","rectangle.2.swap","Source"){open("Source")}
                        control("favorite",library.favorites.contains(item.id) ? "star.fill" : "star","Favourite"){library.toggle(item)}
                        control("audio","speaker.wave.2","Audio"){open("Audio")}
                        control("subs","captions.bubble","Subtitles"){open("Subtitles")}
                        control("quality","4k.tv","Quality"){open("Quality")}
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
                Button{show()}label:{Color.black.opacity(0.001).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())}.buttonStyle(.plain).focused($focus,equals:"wake").accessibilityLabel("Show playback controls").onMoveCommand{_ in show()}
            }
            if let pane=panel { panelView(pane) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(.black)
        .onAppear { assignFocus("pause") }
        .onPlayPauseCommand{session.togglePause()}
        .onExitCommand{if panel != nil {closePanel()} else if visible {hide()} else {onClose()}}
    }
    private func assignFocus(_ key:String){Task{@MainActor in await Task.yield();focus=key}}
    private func show(){visible=true;assignFocus("pause")}
    private func hide(){panel=nil;visible=false;assignFocus("wake")}
    private func open(_ name:String){panel=name;assignFocus("panelClose")}
    private func closePanel(){panel=nil;assignFocus("pause")}
    private func step(_ delta:Int){if let i=index,channels.indices.contains(i+delta){onSelect(channels[i+delta])}}
    private func seek(_ delta:Double){let t=session.native.currentTime().seconds;guard t.isFinite else{return};session.native.seek(to:CMTime(seconds:max(0,t+delta),preferredTimescale:600))}
    private func control(_ key:String,_ icon:String,_ title:String,enabled:Bool=true,action:@escaping ()->Void)->some View {
        Button(action:action){VStack(spacing:6){Image(systemName:icon).font(.system(size:30,weight:.medium));Text(title).font(.system(size:18,weight:.medium)).lineLimit(1).minimumScaleFactor(0.7)}.frame(maxWidth:.infinity).frame(height:88).foregroundStyle(focus==key ? Color.black : Color.white).background(RoundedRectangle(cornerRadius:12).fill(focus==key ? Color.white : Color.white.opacity(0.12)))}.buttonStyle(.plain).focused($focus,equals:key).disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
    private func option(_ key:String,_ title:String,chosen:Bool=false,action:@escaping ()->Void)->some View {
        Button(action:action){HStack{Text(title).font(.system(size:25)).lineLimit(nil).fixedSize(horizontal:false,vertical:true);Spacer();if chosen {Image(systemName:"checkmark.circle.fill")}}.padding(12).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(focus==key ? Color.black : Color.white).background(RoundedRectangle(cornerRadius:10).fill(focus==key ? Color.white : Color.white.opacity(0.08)))}.buttonStyle(.plain).focused($focus,equals:key)
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
                case "Channels":
                    ForEach(channels){m in option("channel-"+m.id,m.name,chosen:m.id==item.id){onSelect(m);closePanel()}}
                case "Audio","Subtitles":
                    let tracks=session.tracks(name)
                    if tracks.isEmpty {Text("No selectable tracks reported by this player.").font(.system(size:22)).foregroundStyle(.secondary)}
                    ForEach(tracks){t in option("track-"+String(t.id),t.name,chosen:t.selected){session.chooseTrack(name,t.id)}}
                case "Quality":
                    Text(session.status).font(.system(size:22)).foregroundStyle(.secondary)
                    if session.engine == "AVPlayer" {
                        Text("Adaptive stream bitrate limit (not a fixed resolution). Original removes the cap.").font(.system(size:20)).foregroundStyle(.secondary)
                        ForEach([0.0,3_000_000,6_000_000,12_000_000,25_000_000],id:\.self){cap in option("cap-"+String(cap),cap==0 ? "Original / Auto" : "Up to \(Int(cap/1_000_000)) Mbps",chosen:session.qualityCap==cap){session.setQualityCap(cap)}}
                    } else {
                        Text("Available video tracks, not adaptive HLS variants. VLC chooses quality automatically when no alternatives are exposed.").font(.system(size:20)).foregroundStyle(.secondary)
                        ForEach(session.tracks("Quality")){t in option("video-"+String(t.id),t.name,chosen:t.selected){session.chooseTrack("Quality",t.id)}}
                    }
                case "Player":
                    ForEach(["Auto","AVPlayer","VLC"],id:\.self){engine in option("engine-"+engine,engine,chosen:session.engine==engine){session.chooseEngine(engine)}}
                    option("reload","Reload stream"){session.reload()}
                default:
                    Text(item.name).font(.system(size:27,weight:.semibold));Text("Playlist: "+sourceName);Text("Category: "+item.group);Text("Engine: "+session.engine);Text(session.status);if let host=httpURL(item.url)?.host {Text("Server: "+host)}
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
        FullPlayer(item:current ?? item,session:session,library:library,channels:[],onSelect:{m in current=m;library.watched(m);session.start(m)},onClose:{dismiss()}).onAppear{session.start(item)}.onDisappear{session.stop()}
    }
}
