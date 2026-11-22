import SwiftUI
import AVKit
import Combine

// Fixed-size app focus styling: no system white platter or scale-up.
struct CompactFocusStyle: ButtonStyle {
    var inset: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        FocusLabel(label: configuration.label, pressed: configuration.isPressed, inset: inset)
    }
    private struct FocusLabel<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool
        let inset: CGFloat
        var body: some View {
            label
                .padding(.horizontal, inset)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(focused ? Color.cyan.opacity(pressed ? 0.20 : 0.10) : Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.cyan.opacity(0.95) : Color.clear, lineWidth: 2))
        }
    }
}
// For controls that draw their focus indicator inside their own label.
struct ManualFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

@MainActor final class Library: ObservableObject {
    @Published var sources:[Source] = []
    @Published var media:[Media] = []
    @Published var favorites:Set<String> = []
    @Published var history:[String] = []
    @Published var bookmarks:[String:PlaybackBookmark] = [:]
    @Published var movieCache:[String:MovieInformation] = [:]
    func bookmark(for item:Media)->PlaybackBookmark? { bookmarks[item.id] }
    func record(_ item:Media,seconds:Double,duration:Double) {
        guard item.kind != .live, seconds.isFinite, duration.isFinite, duration>0,
              seconds>=0 else { return }
        let done=seconds/duration >= 0.95
        bookmarks[item.id]=PlaybackBookmark(seconds:seconds,duration:duration,updated:Date(),completed:done)
        if let data=try? JSONEncoder().encode(bookmarks) {UserDefaults.standard.set(data,forKey:"vodBookmarksV1")}
    }
    func forgetProgress(){bookmarks=[:];UserDefaults.standard.removeObject(forKey:"vodBookmarksV1")}
    func clearProgress(_ item:Media){bookmarks[item.id]=nil;if let data=try? JSONEncoder().encode(bookmarks){UserDefaults.standard.set(data,forKey:"vodBookmarksV1")}}
    func movieInformation(for item:Media)->MovieInformation?{movieCache[item.id]}
    func loadMovieInformation(_ item:Media) async {
        guard movieCache[item.id]==nil,let source=sources.first(where:{$0.id==item.sourceID}) else{return}
        if let info=await fetchMovieInformation(source:source,item:item) {
            movieCache[item.id]=info
            if let data=try? JSONEncoder().encode(movieCache){UserDefaults.standard.set(data,forKey:"movieMetadataV1")}
        }
    }
    @Published var guides:[UUID:GuideSnapshot] = [:]
    @Published var epgBusy = false
    @Published var guideClock=Date()
    @Published var epgStatus = ""
    @Published var manualGuideIDs:[String:String] = [:]
    private var attempts:[UUID:Date] = [:]
    private var guideEpoch = 0
    private var guideFolder:URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("epg-v1",isDirectory:true) }
    private func guideFile(_ id:UUID)->URL { guideFolder.appendingPathComponent(id.uuidString+".json") }
    func programmes(_ item:Media, after:Date? = nil)->[Programme] {
        let p=guides[item.sourceID]?.programmes(item) ?? [];return after.map{d in p.filter{$0.end>d}} ?? p
    }
    func currentProgramme(_ item:Media,at:Date?=nil)->Programme? { let now=at ?? guideClock;return programmes(item).first{$0.start<=now && $0.end>now} }
    func nextProgramme(_ item:Media,at:Date?=nil)->Programme? { let now=at ?? guideClock;return programmes(item).first{$0.start>now} }
    func guideLabel(_ item:Media)->String? { guard let snapshot=guides[item.sourceID],let key=snapshot.links[item.id] else{return nil};return snapshot.labels[key] }
    func setGuideID(_ item:Media,_ value:String) {
        let v=value.trimmingCharacters(in:.whitespacesAndNewlines);manualGuideIDs[item.id]=v.isEmpty ? nil : v
        defaults.set(manualGuideIDs,forKey:"manualGuideIDs")
    }
    func clearGuides() { guideEpoch+=1;guides=[:];attempts=[:];try? FileManager.default.removeItem(at:guideFolder);epgStatus="Guide cache cleared." }
    private func persistGuide(_ guide:GuideSnapshot,for id:UUID) {
        guard let data=try? JSONEncoder().encode(guide),data.count<=64*1024*1024 else {epgStatus += " Guide exceeds disk-cache limit.";return}
        try? FileManager.default.createDirectory(at:guideFolder,withIntermediateDirectories:true)
        try? data.write(to:guideFile(id),options:.atomic)
    }
    @Published var busy = false
    @Published var message = ""
    private let defaults = UserDefaults.standard
    private var cache: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("stream-catalog.json") }
    // tvOS local support storage may reject new large playlist files. Keep LAN
    // imports in the same writable, purgeable cache hierarchy used by the catalog.
    // A deleted cache is reported clearly on the next refresh (re-import required).
    private var importFolder: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("imported-m3u",isDirectory:true) }
    private var legacyImportFolder: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("imported-m3u",isDirectory:true) }
    private func migrateImportedSources() {
        var migrated = false
        for i in sources.indices where sources[i].type == "Local M3U" {
            let old = URL(fileURLWithPath:sources[i].address)
            guard old.path.hasPrefix(legacyImportFolder.path+"/"), FileManager.default.fileExists(atPath:old.path) else { continue }
            let new = importFolder.appendingPathComponent(old.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at:importFolder,withIntermediateDirectories:true)
                if !FileManager.default.fileExists(atPath:new.path) { try FileManager.default.copyItem(at:old,to:new) }
                sources[i].address = new.path; migrated=true
            } catch { message = "Could not migrate imported playlist: \(error.localizedDescription)" }
        }
        if migrated { save() }
    }
    func importM3UFile(_ contents:String, name:String) async -> Bool {
        let displayName=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !displayName.isEmpty,displayName.count<=80 else {
            message="Enter a playlist name of 1–80 characters.";return false
        }
        let id=UUID()
        let path=importFolder.appendingPathComponent(id.uuidString+".m3u")
        do {
            try FileManager.default.createDirectory(at:importFolder,withIntermediateDirectories:true)
            try Data(contents.utf8).write(to:path,options:.atomic)
        } catch {message="Could not store imported playlist in the TV cache: \(error.localizedDescription)";return false}
        let source=Source(id:id,name:displayName,address:path.path,type:"Local M3U")
        let ok=await load(source)
        if !ok {try? FileManager.default.removeItem(at:path)}
        return ok
    }
    init() {
        sources = (try? JSONDecoder().decode([Source].self,from:defaults.data(forKey:"sources") ?? Data())) ?? []
        media = (try? JSONDecoder().decode([Media].self,from:Data(contentsOf:cache))) ?? []
        favorites = Set(defaults.stringArray(forKey:"favorites") ?? [])
        history = defaults.stringArray(forKey:"history") ?? []
        bookmarks = (try? JSONDecoder().decode([String:PlaybackBookmark].self,from:defaults.data(forKey:"vodBookmarksV1") ?? Data())) ?? [:]
        movieCache = (try? JSONDecoder().decode([String:MovieInformation].self,from:defaults.data(forKey:"movieMetadataV1") ?? Data())) ?? [:]
        PlaybackCrashGuard.inspectPreviousLaunch()
        manualGuideIDs = defaults.dictionary(forKey:"manualGuideIDs") as? [String:String] ?? [:]
        migrateImportedSources()
        for source in sources {if let data=try? Data(contentsOf:guideFile(source.id)),let cached=try? JSONDecoder().decode(GuideSnapshot.self,from:data){guides[source.id]=cached}}
    }
    func save() {
        if let data=try? JSONEncoder().encode(sources) { defaults.set(data,forKey:"sources") }
        if let data=try? JSONEncoder().encode(media) { try? FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true); try? data.write(to:cache,options:.atomic) }
        defaults.set(Array(favorites),forKey:"favorites"); defaults.set(history,forKey:"history")
    }
    func toggle(_ item:Media) { if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }; save() }
    func moveSource(_ source:Source,offset:Int) {
        guard let index=sources.firstIndex(where:{$0.id==source.id}),sources.indices.contains(index+offset) else{return}
        sources.swapAt(index,index+offset);save()
    }
    func watched(_ item:Media) { history.removeAll { $0 == item.id }; history.insert(item.id,at:0); history=Array(history.prefix(100)); defaults.set(history,forKey:"history") }
    func remove(_ source:Source) { if source.type == "Local M3U" && (source.address.hasPrefix(importFolder.path+"/") || source.address.hasPrefix(legacyImportFolder.path+"/")) {try? FileManager.default.removeItem(atPath:source.address)};let ids=Set(media.filter{$0.sourceID == source.id}.map(\.id)); favorites.subtract(ids); history.removeAll{ids.contains($0)}; sources.removeAll{$0.id == source.id}; media.removeAll{$0.sourceID == source.id}; guides[source.id]=nil; attempts[source.id]=nil; try? FileManager.default.removeItem(at:guideFile(source.id)); for id in ids {manualGuideIDs[id]=nil;bookmarks[id]=nil;movieCache[id]=nil};defaults.set(manualGuideIDs,forKey:"manualGuideIDs");if let data=try? JSONEncoder().encode(bookmarks){defaults.set(data,forKey:"vodBookmarksV1")};if let data=try? JSONEncoder().encode(movieCache){defaults.set(data,forKey:"movieMetadataV1")}; save() }
    func load(_ s:Source) async -> Bool {
        guard !busy else { return false }; busy=true; message=""; defer {busy=false}
        var s=s
        do {
            var items:[Media]=[]
            var playlistKeys:[PlaylistClearKey]=[]
            var playlistWarnings:[String]=[]
            func readPlaylist(_ text:String) {
                let parsed=parseM3UDetailed(text,source:s)
                items=parsed.media
                playlistKeys=parsed.keys
                playlistWarnings=parsed.warnings
            }
            if s.type == "Xtream" {
                let api=Xtream(source:s)
                var failed:[String]=[]
                for kind in [MediaKind.live,.movie,.series] { do { items += try await api.catalog(kind) } catch { failed.append(kind.rawValue) } }
                if !failed.isEmpty { message="Unavailable sections: "+failed.joined(separator:", ") }
            } else if s.type == "Pasted M3U" { s.discoveredEPG=guideURLs(in:s.pasted,base:nil);readPlaylist(s.pasted) }
            else if s.type == "Local M3U" {
                let raw=try Data(contentsOf:URL(fileURLWithPath:s.address))
                guard let text=String(data:raw,encoding:.utf8) ?? String(data:raw,encoding:.isoLatin1) else {throw StreamFailure.invalidData}
                s.discoveredEPG=guideURLs(in:text,base:nil)
                readPlaylist(text)
            }
            else {
                guard let url=httpURL(s.address) else {throw StreamFailure.invalidURL}
                let data=try await fetch(url); guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else {throw StreamFailure.invalidData}; s.discoveredEPG=guideURLs(in:text,base:url);readPlaylist(text)
            }
            guard !items.isEmpty else {throw StreamFailure.empty}
            // Import only credentials explicitly supplied by the M3U. Never
            // overwrite a user-edited profile; store secrets in tvOS Keychain.
            var keyFailures=0
            for key in playlistKeys where ClearKeyVault.shared.profile(for:key.streamURL) == nil {
                let profile=ClearKeyProfile(streamURL:key.streamURL,method:"Manual key",keyID:key.keyIDHex,keyHex:key.keyHex)
                do {try ClearKeyVault.shared.save(profile)} catch {keyFailures += 1}
            }
            if keyFailures>0 {message="Imported channels; \(keyFailures) ClearKey configuration(s) could not be stored securely."}
            else if !playlistWarnings.isEmpty {message=playlistWarnings.prefix(2).joined(separator:" ")}
            media.removeAll{$0.sourceID == s.id}; media += items
            if let index=sources.firstIndex(where:{$0.id == s.id}) {sources[index]=s} else {sources.append(s)}; save(); if defaults.object(forKey:"epgOnImport") as? Bool ?? true {let imported=s;Task{await self.loadGuide(imported)}}; return true
        } catch { message = (error as? StreamFailure)?.localizedDescription ?? "Import failed. Check the server, credentials and network connection."; return false }
    }
    func loadGuide(_ s:Source) async {
        guard !epgBusy else {epgStatus="A guide refresh is already running.";return}
        guard sources.contains(s) else{return}
        var s=s
        let items=media.filter{$0.sourceID==s.id && $0.kind == .live};guard !items.isEmpty else{epgStatus="No live channels in this playlist.";return}
        epgBusy=true;attempts[s.id]=Date();epgStatus="Updating guide for \(s.name)…";let epoch=guideEpoch
        defer{epgBusy=false}
        let options=GuideOptions.read(defaults);let manual=manualGuideIDs
        // Upgrade existing v0.2.3 playlists, whose header URLs were not persisted.
        if options.provider,s.discoveredEPG==nil,s.type != "Xtream" {
            let original=s
            let discovered=await Task.detached(priority:.utility){ () -> [String]? in
                if original.type == "Pasted M3U" {return guideURLs(in:original.pasted,base:nil)}
                guard let url=httpURL(original.address),let bytes=try? await downloadGuide(url),let text=String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:.isoLatin1) else{return nil}
                return guideURLs(in:text,base:url)
            }.value
            guard epoch==guideEpoch,let index=sources.firstIndex(of:original) else{return}
            if let discovered=discovered {s.discoveredEPG=discovered;sources[index]=s;save()}
        }
        let guideSource=s
        let result=await Task.detached(priority:.utility){await refreshGuide(source:guideSource,items:items,options:options,manual:manual)}.value
        guard epoch==guideEpoch,sources.contains(s) else{return}
        if (!options.provider && !options.custom && !options.external) {guides[s.id]=nil;try? FileManager.default.removeItem(at:guideFile(s.id));epgStatus="All EPG sources disabled.";return}
        if result.feeds==0 || (result.matched==0 && result.failures>0) {epgStatus="No usable guide downloaded for \(s.name). "+result.status.joined(separator:" · ");return}
        var snapshot=result
        // If a feed failed, retain still-relevant old schedules for newly unmatched channels.
        if result.failures>0,let old=guides[s.id] {
            let now=Date();for item in items where snapshot.links[item.id]==nil && manual[item.id]==nil {
                guard let oldKey=old.links[item.id],let ps=old.schedules[oldKey]?.filter({$0.end>now}),!ps.isEmpty else{continue}
                let key="previous|"+oldKey;snapshot.links[item.id]=key;snapshot.schedules[key]=ps;snapshot.labels[key]="Cached "+(old.labels[oldKey] ?? "guide")
            };snapshot.matched=snapshot.links.count
        }
        guides[s.id]=snapshot;guideClock=Date();epgStatus="\(s.name): \(snapshot.matched)/\(snapshot.total) channels matched; \(snapshot.feeds) feeds, \(snapshot.failures) failed.";persistGuide(snapshot,for:s.id)
    }
    func refreshAllGuides(force:Bool=false) async {
        guard !epgBusy else{return}
        let interval=Double(defaults.object(forKey:"epgInterval") as? Int ?? 12)*3600
        for s in sources {if Task.isCancelled{return};let last=guides[s.id]?.updated ?? .distantPast;let attempt=attempts[s.id] ?? .distantPast
            if force || (Date().timeIntervalSince(last)>=interval && Date().timeIntervalSince(attempt)>900){await loadGuide(s)}
        }
    }
}
@main struct StreamLoungeApp: App {
    @StateObject private var library=Library()
    var body: some Scene { WindowGroup { Home(library:library).preferredColorScheme(.dark).buttonStyle(CompactFocusStyle()) } }
}
enum Page:String,CaseIterable,Hashable {case home="Dashboard",live="Live TV",guide="TV Guide",movies="Movies",series="Series",favorites="Favorites",history="Recently viewed",sources="Playlists",settings="Settings"}
enum HomeFocus: Hashable { case nav(Page), content, channel(String), settingsSection(String), settingsOption }
struct Home:View {
    @State private var didApplyStartupPage=false
    @FocusState private var homeFocus: HomeFocus?
    @AppStorage("textDensity") private var textDensity = "Compact"
    private var labelSize: CGFloat { textDensity == "Large" ? 30 : textDensity == "Standard" ? 26 : 22 }
    @ObservedObject var library:Library
    @Environment(\.scenePhase) private var scenePhase
    @State private var page:Page = .home
    @State private var selected:Media?
    @State private var expanded=false
    @StateObject private var playback=PlaybackSession()
    @AppStorage("appearance") private var appearance="Night Owl"
    @State private var filter="All groups"
    @State private var sourceFilter="All sources"
    @State private var query=""
    @State private var showPlaylistPicker=false
    @State private var play:Media?
    @State private var details:Media?
    @State private var editor:Source?
    @State private var add=false
    @State private var guideItem:Media?
    @State private var removeSource:Source?
    @State private var showExitConfirmation=false
    private var base:[Media] {
        let all=library.media
        switch page {
        case .live:return all.filter{$0.kind == .live}
        case .movies:return all.filter{$0.kind == .movie}
        case .series:return all.filter{$0.kind == .series || $0.kind == .episode}
        case .favorites:return all.filter{library.favorites.contains($0.id)}
        case .home,.history:let lookup=Dictionary(all.map{($0.id,$0)},uniquingKeysWith:{a,_ in a}); return library.history.compactMap{lookup[$0]}
        case .guide:return all.filter{$0.kind == .live}
        case .sources,.settings:return []
        }
    }
    private var scoped:[Media] {base.filter{sourceFilter == "All sources" || $0.sourceID.uuidString == sourceFilter}}
    private var groups:[String] {Array(Set(scoped.map(\.group))).sorted()}
    private var shown:[Media] {scoped.filter{(filter == "All groups" || $0.group == filter) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))}}
    var body:some View {
        HStack(alignment:.top,spacing:0) {
            if !expanded {
                VStack(alignment:.leading,spacing:12) {
                    HStack(spacing:8){Image(systemName:"play.tv.fill").font(.system(size:25));Text("Stream Lounge").font(.system(size:28,weight:.bold)).lineLimit(1).minimumScaleFactor(0.65)}.foregroundStyle(.cyan).frame(maxWidth:.infinity,alignment:.leading)
                    VStack(alignment:.leading,spacing:4) {
                        ForEach(Page.allCases,id:\.self){p in
                            Button { openPage(p, enter:true) } label:{
                                HStack(spacing:12){Image(systemName:pageIcon(p)).frame(width:28);Text(p.rawValue).lineLimit(1).minimumScaleFactor(0.65);Spacer(minLength:0)}
                                    .font(.system(size:labelSize,weight:.medium)).padding(.horizontal,12).frame(height:58)
                                    .foregroundStyle(homeFocus == .nav(p) || page == p ? Color.cyan : Color.white)
                                    .background(RoundedRectangle(cornerRadius:8).fill(homeFocus == .nav(p) ? Color.cyan.opacity(0.14) : page == p ? Color.cyan.opacity(0.07) : Color.clear))
                                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(homeFocus == .nav(p) ? Color.cyan : Color.clear,lineWidth:2))
                            }.buttonStyle(ManualFocusStyle()).focused($homeFocus,equals:.nav(p))
                        }
                    }.onMoveCommand { direction in
                        // Let the tvOS focus engine handle Up/Down. Doing both
                        // automatic navigation and manual focus moves skipped rows.
                        if direction == .right { moveSidebarRight() }
                    }
                    Spacer(minLength:0)
                    Button { showExitConfirmation=true } label: {
                        Label("Exit",systemImage:"rectangle.portrait.and.arrow.right")
                            .font(.system(size:labelSize,weight:.medium))
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .foregroundStyle(.white)
                    }.buttonStyle(CompactFocusStyle())
                    Text("v0.3.3").font(.system(size:19)).foregroundStyle(.secondary)
                }.padding(18).frame(width:300).frame(maxHeight:.infinity,alignment:.topLeading).focusSection().background(Color.white.opacity(0.045))
            }
            VStack(alignment:.leading,spacing:14) {
                if !expanded { HStack {Text(page.rawValue).font(.title.bold());Spacer();if library.busy || library.epgBusy {ProgressView()};Text("\(library.media.count) items").font(.caption).foregroundStyle(.secondary)} }
                if !library.message.isEmpty && !expanded {Text(library.message).font(.caption).foregroundStyle(.yellow)}
                if page == .settings {SettingsView(library:library,entryFocus:$homeFocus)}
                else if page == .sources {sourceView}
                else if page == .live {liveView}
                else if page == .guide {guideBrowser}
                else if page == .home {dashboard}
                else {browseView}
            }.padding(expanded ? 0 : 24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).focusSection()
        }.background(backgroundColor.ignoresSafeArea()).onExitCommand {if expanded {return} else if selected != nil {playback.stop();selected=nil} else {page = .home}}
        .task {
            if !didApplyStartupPage {
                didApplyStartupPage=true
                let preferred=UserDefaults.standard.string(forKey:"startPage") ?? "Dashboard"
                if let p=Page.allCases.first(where:{$0.rawValue==preferred}) {page=p}
                if UserDefaults.standard.bool(forKey:"autoRefreshPlaylists") {
                    for source in library.sources where source.type != "Pasted M3U" { _ = await library.load(source) }
                }
            }
            if UserDefaults.standard.object(forKey:"epgOnStart") as? Bool ?? true {await library.refreshAllGuides()}
            while !Task.isCancelled {try? await Task.sleep(nanoseconds:60_000_000_000);if !Task.isCancelled && scenePhase == .active {library.guideClock=Date();await library.refreshAllGuides()}}
        }.onChange(of:scenePhase){phase in if phase == .active {Task{await library.refreshAllGuides()}}}
        .fullScreenCover(item:$play){item in Playback(item:item,library:library)}
        .sheet(item:$details){item in
            if item.kind == .series { SeriesView(item:item,library:library) }
            else { MovieDetailsView(item:item,library:library) }
        }
        .sheet(isPresented:$showPlaylistPicker){PlaylistSelectionView(sources:library.sources,selected:$sourceFilter)}
        .sheet(item:$guideItem){item in
            GuideView(item:item,library:library,onPlay:{channel in
                guideItem=nil
                openPage(.live,enter:false)
                selectChannel(channel)
            })
        }
        .sheet(item:$editor){s in SourceEditor(library:library,source:s)}
        .sheet(isPresented:$add){SourceEditor(library:library,source:Source(name:"",address:"",type:"M3U URL"))}
        .alert("Remove source?",isPresented:Binding(get:{removeSource != nil},set:{if !$0 {removeSource=nil}})){Button("Remove",role:.destructive){if let s=removeSource{library.remove(s)};removeSource=nil};Button("Cancel",role:.cancel){removeSource=nil}}
        .alert("Exit Stream Lounge TV?",isPresented:$showExitConfirmation) {
            Button("Stop and return to Dashboard",role:.destructive) {
                playback.stop();selected=nil;play=nil;lanImporter.stop();page = .home
                library.message = "Playback stopped. Press the Apple TV Home button to leave the app."
            }
            Button("Cancel",role:.cancel) {}
        } message: {
            Text("tvOS does not provide a public API to quit an app. Exit will stop playback and return to the Dashboard. Use the TV/Home button to leave the app.")
        }
    }
    private func openPage(_ p:Page,enter:Bool) {
        if p != page {playback.stop(); selected=nil; filter="All groups";sourceFilter="All sources";query="";page=p}
        if p == .live,(UserDefaults.standard.object(forKey:"rememberLastChannel") as? Bool ?? true),
           selected == nil,let last=UserDefaults.standard.string(forKey:"lastLiveChannelID"),
           let channel=library.media.first(where:{$0.id==last && $0.kind == .live}) {
            selectChannel(channel)
        }
        if enter { Task { @MainActor in await Task.yield(); homeFocus = .content } }
    }
    private func moveSidebarRight() {
        guard case let .nav(p)? = homeFocus else {return}
        openPage(p,enter:true)
    }
    private var backgroundColor:Color { appearance == "Black OLED" ? .black : Color(red:0.055,green:0.075,blue:0.12) }
    private func pageIcon(_ p:Page)->String { switch p {case .home:return "house";case .live:return "tv";case .guide:return "calendar";case .movies:return "film";case .series:return "play.rectangle.on.rectangle";case .favorites:return "star";case .history:return "clock";case .sources:return "list.bullet";case .settings:return "gearshape"} }
    private func selectChannel(_ item:Media) {
        selected=item;library.watched(item)
        if UserDefaults.standard.object(forKey:"rememberLastChannel") as? Bool ?? true {
            UserDefaults.standard.set(item.id,forKey:"lastLiveChannelID")
        } else { UserDefaults.standard.removeObject(forKey:"lastLiveChannelID") }
        playback.start(item)
    }
    private var currentPlaylistName:String {
        guard sourceFilter != "All sources",let id=UUID(uuidString:sourceFilter) else{return "All playlists"}
        return library.sources.first(where:{$0.id==id})?.name ?? "All playlists"
    }
    private var channelFilters:some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Playlist").font(.system(size:20,weight:.semibold)).lineLimit(1)
            Button { showPlaylistPicker=true } label: {
                HStack(alignment:.top,spacing:12) {
                    Text(currentPlaylistName)
                        .font(.system(size:19,weight:.medium))
                        .lineLimit(nil)
                        .fixedSize(horizontal:false,vertical:true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth:.infinity,alignment:.leading)
                    Image(systemName:"chevron.up.chevron.down").font(.system(size:18))
                }
                .foregroundStyle(.cyan)
                .padding(.horizontal,12).padding(.vertical,12)
                .frame(maxWidth:.infinity,alignment:.leading)
                .background(RoundedRectangle(cornerRadius:8).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(.cyan.opacity(0.30),lineWidth:1))
            }
            .buttonStyle(CompactFocusStyle(inset:0))
            .focused($homeFocus,equals:.content)
            .accessibilityLabel("Choose playlist: " + currentPlaylistName)
            .onChange(of:sourceFilter){_ in filter="All groups"}
            Text("Categories").font(.system(size:20,weight:.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    ForEach(["All groups"]+groups,id:\.self) { g in
                        Button {filter=g} label: {
                            Text(g)
                                .font(.system(size:min(21,labelSize)))
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth:.infinity,alignment:.leading)
                                .foregroundStyle(filter == g ? Color.cyan : Color.primary)
                        }
                    }
                    .padding(8)
                }
            }
        }.frame(width:410).frame(maxHeight:.infinity,alignment:.top).focusSection()
    }
    private var liveView:some View {
        HStack(alignment:.top,spacing:16) {
            if !expanded {
                channelFilters
                VStack(alignment:.leading,spacing:10) {
                    TextField("Search channels",text:$query).font(.system(size:labelSize))
                    ScrollView {LazyVStack(alignment:.leading,spacing:8){ForEach(shown){item in
                        Button{selectChannel(item)}label:{HStack(alignment:.center,spacing:10){
                            if let logo=httpURL(item.logo){AsyncImage(url:logo){image in image.resizable().scaledToFit()}placeholder:{Image(systemName:"tv")}.frame(width:45,height:32)}else{Image(systemName:"tv").frame(width:45)}
                            VStack(alignment:.leading,spacing:3){ViewThatFits(in:.horizontal){Text(item.name).font(.system(size:labelSize)).fixedSize(horizontal:true,vertical:false);Text(item.name).font(.system(size:max(18,labelSize-4))).fixedSize(horizontal:true,vertical:false);Text(item.name).font(.system(size:max(18,labelSize-4))).lineLimit(nil).fixedSize(horizontal:false,vertical:true)}.layoutPriority(1).frame(maxWidth:.infinity,alignment:.leading)
                            if let p=library.currentProgramme(item){Text(p.title).font(.system(size:17)).lineLimit(1).foregroundStyle(.secondary);ProgressView(value:min(1,max(0,Date().timeIntervalSince(p.start)/max(1,p.end.timeIntervalSince(p.start))))).tint(.cyan).frame(maxWidth:150)} }.frame(maxWidth:.infinity,alignment:.leading)
                            if library.favorites.contains(item.id){Image(systemName:"star.fill").font(.system(size:19)).foregroundStyle(.yellow)}
                        }.foregroundStyle(selected?.id == item.id ? Color.cyan : Color.primary).padding(.vertical,3).frame(maxWidth:.infinity,alignment:.leading)}.focused($homeFocus,equals:.channel(item.id)).contextMenu{Button(library.favorites.contains(item.id) ? "Remove favorite" : "Add favorite"){library.toggle(item)}}
                    }}.padding(8)}
                }.frame(width:490).frame(maxHeight:.infinity,alignment:.top).focusSection()
            }
            VStack(alignment:.leading,spacing:12) {
                if let item=selected {
                    if expanded {
                        FullPlayer(item:item,session:playback,library:library,channels:library.media.filter{$0.kind == .live},onSelect:{selectChannel($0)},onClose:{expanded=false;Task{@MainActor in await Task.yield();homeFocus = .channel(item.id)}})
                    } else {
                        PlayerSurface(session:playback).aspectRatio(16/9,contentMode:.fit).frame(maxWidth:.infinity,maxHeight:500).background(.black)
                        Text(item.name).font(.system(size:labelSize+4,weight:.semibold)).lineLimit(nil).fixedSize(horizontal:false,vertical:true)
                        HStack(spacing:14){Button("Fullscreen"){expanded=true};Button{library.toggle(item)}label:{Image(systemName:library.favorites.contains(item.id) ? "star.fill" : "star")};Button{step(-1)}label:{Image(systemName:"backward.end.fill")};Button{step(1)}label:{Image(systemName:"forward.end.fill")}}.font(.system(size:22))
                        Text(playback.status).font(.system(size:19)).foregroundStyle(.secondary)
                        programmePanel(item)
                    }
                } else {Spacer();Image(systemName:"tv").font(.largeTitle);Text("Select a channel to play").font(.headline);Spacer()}
            }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).focusSection()
        }
    }
    private func step(_ delta:Int) {guard let item=selected,let i=shown.firstIndex(where:{$0.id==item.id}),shown.indices.contains(i+delta)else{return};selectChannel(shown[i+delta])}
    private func programmePanel(_ item:Media)->some View {
        let programmes=library.programmes(item,after:Date())
        return VStack(alignment:.leading,spacing:10){HStack{Text("Programme guide").font(.headline);Spacer();Button("Refresh guide"){if let s=library.sources.first(where:{$0.id==item.sourceID}){Task{await library.loadGuide(s)}}}.font(.caption2).disabled(library.epgBusy)};if programmes.isEmpty{Text("No matched schedule. Check EPG settings or refresh the guide.").font(.caption).foregroundStyle(.secondary)}else{ScrollView(.horizontal){HStack{ForEach(Array(programmes.prefix(12))){p in VStack(alignment:.leading){Text(p.start.formatted(date:.omitted,time:.shortened));Text(p.title).lineLimit(2)}.font(.caption2).padding(10).frame(width:240,height:90,alignment:.topLeading).background(p.start<=Date() ? Color.blue.opacity(0.45) : Color.white.opacity(0.08))}}}}}
    }
    private func startFromGuide(_ item:Media) {
        guard item.kind == .live else{return}
        library.watched(item)
        play=item
    }
    private var guideBrowser:some View {
        HStack(alignment:.top,spacing:20){channelFilters;GuideTimeline(items:shown,library:library,play:{startFromGuide($0)},details:{guideItem=$0})}
    }
    private var dashboard:some View {ScrollView{VStack(alignment:.leading,spacing:25){if library.sources.isEmpty{Text("Add your first playlist").font(.title2);Button("Add playlist"){add=true}.focused($homeFocus,equals:.content)}else{HStack{Button{openPage(.live,enter:true)}label:{Label("Live TV",systemImage:"tv")}.focused($homeFocus,equals:.content);ForEach([Page.movies,.series,.sources],id:\.self){p in Button{openPage(p,enter:true)}label:{Label(p.rawValue,systemImage:pageIcon(p))}}};dashboardRow("Continue watching",library.media.filter{($0.kind == .movie || $0.kind == .episode) && (library.bookmark(for:$0)?.seconds ?? 0)>=30 && library.bookmark(for:$0)?.completed == false}.sorted{(library.bookmark(for:$0)?.updated ?? .distantPast) > (library.bookmark(for:$1)?.updated ?? .distantPast)});dashboardRow("Recently viewed",base);dashboardRow("Favorites",library.media.filter{library.favorites.contains($0.id)});dashboardRow("Movies",library.media.filter{$0.kind == .movie});dashboardRow("Series",library.media.filter{$0.kind == .series})}}}}
    private func dashboardRow(_ title:String,_ items:[Media])->some View {VStack(alignment:.leading,spacing:10){Text(title).font(.title3.bold());if items.isEmpty{Text("Nothing here yet").font(.caption).foregroundStyle(.secondary)}else{ScrollView(.horizontal){HStack(spacing:25){ForEach(Array(items.prefix(20))){item in Button{if item.kind == .series{details=item}else if item.kind == .live{page = .live;selectChannel(item)}else{details=item}}label:{MediaTile(item:item,favorite:library.favorites.contains(item.id),bookmark:library.bookmark(for:item),poster:library.movieInformation(for:item)?.poster).frame(width:230)}.buttonStyle(CompactFocusStyle(inset: 3))}}.padding(16)}}}}
    private var browseView:some View {
        HStack(alignment:.top,spacing:30){
            VStack(alignment:.leading,spacing:10){
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                ConfirmSelection(title: "Source", selection: $sourceFilter, options: [ConfirmOption("All sources", "All sources")] + library.sources.map { ConfirmOption($0.id.uuidString, $0.name) }).onChange(of:sourceFilter){_ in filter="All groups"}
                Text("Categories").font(.caption).foregroundStyle(.secondary)
                ScrollView {LazyVStack(alignment:.leading,spacing:12){ForEach(["All groups"]+groups,id:\.self){g in Button {filter=g} label:{Text(g).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(filter == g ? Color.cyan : Color.primary)}}}}
            }.frame(width:365)
            VStack(alignment:.leading,spacing:14){
                HStack {Text(page == .home ? "Recently watched" : page.rawValue).font(.title2.bold());Spacer();Text("\(shown.count)").foregroundStyle(.secondary)}
                TextField("Search channels, movies or series",text:$query).focused($homeFocus,equals:.content)
                if shown.isEmpty {Text("No items in this view.").foregroundStyle(.secondary);Spacer()}
                else {ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:240),spacing:22)],spacing:35){ForEach(shown){item in
                    Button {if item.kind == .series {details=item} else if item.kind == .live {page = .live;filter="All groups";sourceFilter="All sources";query="";selectChannel(item)} else {details=item}} label:{MediaTile(item:item,favorite:library.favorites.contains(item.id),bookmark:library.bookmark(for:item),poster:library.movieInformation(for:item)?.poster)}
                        .buttonStyle(CompactFocusStyle(inset: 3))
                        .contextMenu {Button(library.favorites.contains(item.id) ? "Remove favorite" : "Add favorite"){library.toggle(item)};if item.kind == .live {Button("Programme guide"){guideItem=item}}}
                }}}}
            }.frame(maxWidth:.infinity)
        }
    }
    @StateObject private var lanImporter=LocalM3UServer()
    private var sourceView:some View {
        VStack(alignment:.leading,spacing:20){HStack(spacing:18){Button{add=true}label:{Label("Add source",systemImage:"plus")}.focused($homeFocus,equals:.content).disabled(library.busy)
            Button(lanImporter.running ? "Stop local transfer" : "Import M3U from phone/computer"){
                if lanImporter.running {lanImporter.stop()} else {
                    lanImporter.onM3U = { contents, name in
                        await library.importM3UFile(contents,name:name)
                    }
                    lanImporter.start()
                }
            }.disabled(library.busy)
            }
            if lanImporter.running {Text("Open "+lanImporter.address+" on your phone or computer. PIN: "+lanImporter.pin).font(.title3).foregroundStyle(.cyan)}
            if !lanImporter.status.isEmpty {Text(lanImporter.status).font(.caption).foregroundStyle(.secondary)}
            if !library.message.isEmpty {Text(library.message).font(.caption).foregroundStyle(.yellow)}
            ScrollView {LazyVStack(alignment:.leading,spacing:25){ForEach(library.sources){s in HStack{VStack(alignment:.leading){Text(s.name).font(.headline);Text(s.type+" · \(library.media.filter{$0.sourceID==s.id}.count) items").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Refresh"){Task{_ = await library.load(s)}}.disabled(library.busy);Button("EPG"){Task{await library.loadGuide(s)}}.disabled(library.epgBusy);Button("Up"){library.moveSource(s,offset:-1)}.disabled(library.busy || library.sources.first?.id==s.id)
                    Button("Down"){library.moveSource(s,offset:1)}.disabled(library.busy || library.sources.last?.id==s.id)
                    Button("Edit"){editor=s}.disabled(library.busy);Button("Remove"){removeSource=s}.disabled(library.busy)}}}}
        }.frame(maxHeight:.infinity,alignment:.topLeading)
         .onDisappear{lanImporter.stop()}
    }
}
struct MediaTile:View {
    var item:Media; var favorite:Bool; var bookmark:PlaybackBookmark? = nil;var poster:String?=nil
    var body:some View {VStack(alignment:.leading,spacing:8){
        ZStack{RoundedRectangle(cornerRadius:12).fill(Color.white.opacity(0.09));if let url=httpURL((poster?.isEmpty == false ? poster : nil) ?? item.logo){AsyncImage(url:url){image in image.resizable().scaledToFit()} placeholder:{Image(systemName:icon).font(.largeTitle).foregroundStyle(.secondary)}}else{Image(systemName:icon).font(.largeTitle).foregroundStyle(.secondary)}}.frame(height:135).clipped()
        HStack{Text(item.name).font(.system(size:24,weight:.medium)).lineLimit(nil).fixedSize(horizontal:false,vertical:true);Spacer(minLength:0);if favorite{Image(systemName:"star.fill").foregroundStyle(.yellow).font(.caption)}}
        Text(item.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if let mark=bookmark,mark.seconds>=30,!mark.completed {
            ProgressView(value:mark.progress).tint(.cyan)
            Text("Resume at "+formatPlaybackTime(Int(mark.seconds))).font(.caption2).foregroundStyle(.secondary)
        }
    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)}
    var icon:String {item.kind == .live ? "tv" : (item.kind == .movie ? "film" : "play.rectangle.on.rectangle")}
}
struct SourceEditor:View {
    @ObservedObject var library:Library
    @State var source:Source
    @Environment(\.dismiss) private var dismiss
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:24){
        Text("Playlist / account").font(.title.bold())
        ConfirmSelection(title: "Source type", selection: $source.type, options: (["M3U URL","Pasted M3U","Xtream"] + (source.type == "Local M3U" ? ["Local M3U"] : [])).map { ConfirmOption($0, $0) }).disabled(library.busy || source.type == "Local M3U")
        TextField("Display name",text:$source.name)
        if source.type == "Pasted M3U" {TextField("Paste M3U text using Apple TV keyboard",text:$source.pasted)} else if source.type == "Local M3U" {Text("Stored locally on Apple TV — use Playlists → Refresh to reload the imported file").foregroundStyle(.secondary)} else {TextField(source.type == "Xtream" ? "Server URL (https://host:port)" : "Playlist URL",text:$source.address)}
        if source.type == "Xtream" {TextField("Username",text:$source.user);SecureField("Password",text:$source.password)}
        TextField("Custom XMLTV URLs (space-separated, optional)",text:$source.epg)
        TextField("EPG country codes (e.g. UK, US, NG, ZA)",text:Binding(get:{source.epgCountries ?? ""},set:{source.epgCountries=$0}))
        Text("Leave country codes blank for automatic detection. Provider and EPGShare guides are discovered on refresh.").font(.caption).foregroundStyle(.secondary)
        if !library.message.isEmpty {Text(library.message).font(.caption).foregroundStyle(.yellow)}
        HStack {Button("Cancel"){dismiss()}.disabled(library.busy);Button("Save and import"){Task{if await library.load(source){dismiss()}}}.disabled(source.name.trimmingCharacters(in:.whitespaces).isEmpty || library.busy);if library.busy{ProgressView()}}
    }.padding(70).frame(maxWidth:1300)}.frame(maxWidth:.infinity)}
}
struct SeriesView:View {
    let item:Media; @ObservedObject var library:Library
    @Environment(\.dismiss) private var dismiss
    @State private var episodes:[Media]=[];@State private var error="";@State private var loading=true;@State private var play:Media?
    var body:some View {VStack(alignment:.leading,spacing:20){HStack{Text(item.name).font(.title.bold());Spacer();Button("Close"){dismiss()}};if loading{ProgressView()}else if !error.isEmpty{Text(error)}else{ScrollView{LazyVStack(alignment:.leading){ForEach(episodes){e in Button{play=e}label:{Text(e.group+" · "+e.name).frame(maxWidth:.infinity,alignment:.leading)}}}}}}.padding(65).task{defer{loading=false};guard let s=library.sources.first(where:{$0.id==item.sourceID})else{return};do{episodes=try await Xtream(source:s).episodes(item);if episodes.isEmpty{error="No episodes returned."}}catch{self.error="Unable to retrieve episodes."}}.fullScreenCover(item:$play){e in Playback(item:e,library:library)}}
}
struct GuideView:View {
    let item:Media; @ObservedObject var library:Library; let onPlay:(Media)->Void
    @Environment(\.dismiss) private var dismiss
    @State private var manualID=""
    var body:some View {
        VStack(alignment:.leading,spacing:20){
            HStack{Text(item.name).font(.title.bold());Spacer();Button("Watch Live"){onPlay(item)};Button("Close"){dismiss()}}
            HStack{Button("Refresh guide"){refresh()}.disabled(library.epgBusy);if library.epgBusy{ProgressView()};Text(library.guideLabel(item) ?? "Unmatched").font(.caption).foregroundStyle(.secondary)}
            HStack{TextField("Manual XMLTV channel ID",text:$manualID);Button("Apply"){library.setGuideID(item,manualID);refresh()}.disabled(library.epgBusy);Button("Automatic"){manualID="";library.setGuideID(item,"");refresh()}.disabled(library.epgBusy)}
            Text(library.epgStatus).font(.caption).foregroundStyle(.secondary)
            ScrollView{LazyVStack(alignment:.leading,spacing:14){ForEach(library.programmes(item,after:Date())){p in VStack(alignment:.leading,spacing:6){Text(p.start.formatted(date:.abbreviated,time:.shortened)+" – "+p.end.formatted(date:.omitted,time:.shortened)).font(.caption).foregroundStyle(.cyan);Text(p.title).font(.headline);if !p.detail.isEmpty{Text(p.detail).font(.caption).foregroundStyle(.secondary)}}.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:8))}}}
        }.padding(65).onAppear{manualID=library.manualGuideIDs[item.id] ?? ""}
    }
    private func refresh(){if let source=library.sources.first(where:{$0.id==item.sourceID}){Task{await library.loadGuide(source)}}}
}

// A full-width, scrolling playlist chooser avoids the intrinsic text truncation
// of the system tvOS Picker and remains reachable using the Siri Remote.
private struct PlaylistSelectionView: View {
    let sources:[Source]
    @Binding var selected:String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused:String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Text("Choose playlist").font(.system(size:38,weight:.bold))
                Spacer()
                Button("Close"){dismiss()}
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        choice("All sources","All playlists")
                        ForEach(sources){source in
                            choice(source.id.uuidString,source.name)
                        }
                    }.padding(.vertical,12)
                }
                .onAppear {
                    let id=selected
                    DispatchQueue.main.async {proxy.scrollTo(id,anchor:.center);focused=id}
                }
            }
        }
        .padding(54)
        .frame(width:1100,height:850,alignment:.topLeading)
        .background(Color(red:0.08,green:0.10,blue:0.15))
    }
    private func choice(_ id:String,_ name:String)->some View {
        Button {
            selected=id
            dismiss()
        } label: {
            HStack(spacing:16) {
                Text(name)
                    .font(.system(size:23))
                    .lineLimit(nil)
                    .fixedSize(horizontal:false,vertical:true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth:.infinity,alignment:.leading)
                if selected == id {Image(systemName:"checkmark.circle.fill").foregroundStyle(.cyan)}
            }
            .padding(15)
            .background(RoundedRectangle(cornerRadius:10).fill(selected == id ? Color.cyan.opacity(0.12) : Color.white.opacity(0.04)))
        }
        .buttonStyle(CompactFocusStyle(inset:3))
        .focused($focused,equals:id)
        .id(id)
    }
}
