import SwiftUI
import AVKit
import Combine

@MainActor final class Library: ObservableObject {
    @Published var sources:[Source] = []
    @Published var media:[Media] = []
    @Published var favorites:Set<String> = []
    @Published var history:[String] = []
    @Published var guide:[Programme] = []
    @Published var guideSource:UUID?
    @Published var busy = false
    @Published var message = ""
    private let defaults = UserDefaults.standard
    private var cache: URL { FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("stream-catalog.json") }
    init() {
        sources = (try? JSONDecoder().decode([Source].self,from:defaults.data(forKey:"sources") ?? Data())) ?? []
        media = (try? JSONDecoder().decode([Media].self,from:Data(contentsOf:cache))) ?? []
        favorites = Set(defaults.stringArray(forKey:"favorites") ?? [])
        history = defaults.stringArray(forKey:"history") ?? []
    }
    func save() {
        if let data=try? JSONEncoder().encode(sources) { defaults.set(data,forKey:"sources") }
        if let data=try? JSONEncoder().encode(media) { try? FileManager.default.createDirectory(at:cache.deletingLastPathComponent(),withIntermediateDirectories:true); try? data.write(to:cache,options:.atomic) }
        defaults.set(Array(favorites),forKey:"favorites"); defaults.set(history,forKey:"history")
    }
    func toggle(_ item:Media) { if favorites.contains(item.id) { favorites.remove(item.id) } else { favorites.insert(item.id) }; save() }
    func watched(_ item:Media) { history.removeAll { $0 == item.id }; history.insert(item.id,at:0); history=Array(history.prefix(100)); defaults.set(history,forKey:"history") }
    func remove(_ source:Source) { let ids=Set(media.filter{$0.sourceID == source.id}.map(\.id)); favorites.subtract(ids); history.removeAll{ids.contains($0)}; sources.removeAll{$0.id == source.id}; media.removeAll{$0.sourceID == source.id}; save() }
    func load(_ s:Source) async -> Bool {
        guard !busy else { return false }; busy=true; message=""; defer {busy=false}
        do {
            var items:[Media]=[]
            if s.type == "Xtream" {
                let api=Xtream(source:s)
                var failed:[String]=[]
                for kind in [MediaKind.live,.movie,.series] { do { items += try await api.catalog(kind) } catch { failed.append(kind.rawValue) } }
                if !failed.isEmpty { message="Unavailable sections: "+failed.joined(separator:", ") }
            } else if s.type == "Pasted M3U" { items=parseM3U(s.pasted,source:s) }
            else {
                guard let url=httpURL(s.address) else {throw StreamFailure.invalidURL}
                let data=try await fetch(url); guard let text=String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else {throw StreamFailure.invalidData}; items=parseM3U(text,source:s)
            }
            guard !items.isEmpty else {throw StreamFailure.empty}
            media.removeAll{$0.sourceID == s.id}; media += items
            if let index=sources.firstIndex(where:{$0.id == s.id}) {sources[index]=s} else {sources.append(s)}; save(); return true
        } catch { message = (error as? StreamFailure)?.localizedDescription ?? "Import failed. Check the server, credentials and network connection."; return false }
    }
    func loadGuide(_ s:Source) async {
        guard !busy else{return}; guard let url=httpURL(s.epg) else {message="Set an XMLTV URL in the source first.";return}; busy=true; defer{busy=false}
        do {guide=try XMLGuide().parse(await fetch(url)); guideSource=s.id; message="Loaded \(guide.count) programmes."} catch {message="Unable to load XMLTV. Use an uncompressed XML file URL."}
    }
}
@main struct StreamLoungeApp: App {
    @StateObject private var library=Library()
    var body: some Scene { WindowGroup { Home(library:library).preferredColorScheme(.dark) } }
}
enum Page:String,CaseIterable,Hashable {case home="Dashboard",live="Live TV",guide="TV Guide",movies="Movies",series="Series",favorites="Favorites",history="Recently viewed",search="Search",sources="Playlists",settings="Settings"}
enum HomeFocus: Hashable { case nav(Page), content, channel(String), settingsSection(String), settingsOption }
struct Home:View {
    @FocusState private var homeFocus: HomeFocus?
    @AppStorage("textDensity") private var textDensity = "Compact"
    private var labelSize: CGFloat { textDensity == "Large" ? 30 : textDensity == "Standard" ? 26 : 22 }
    @ObservedObject var library:Library
    @State private var page:Page = .home
    @State private var selected:Media?
    @State private var expanded=false
    @StateObject private var playback=PlaybackSession()
    @AppStorage("appearance") private var appearance="Night Owl"
    @State private var filter="All groups"
    @State private var sourceFilter="All sources"
    @State private var query=""
    @State private var play:Media?
    @State private var details:Media?
    @State private var editor:Source?
    @State private var add=false
    @State private var guideItem:Media?
    @State private var removeSource:Source?
    private var base:[Media] {
        let all=library.media
        switch page {
        case .live:return all.filter{$0.kind == .live}
        case .movies:return all.filter{$0.kind == .movie}
        case .series:return all.filter{$0.kind == .series || $0.kind == .episode}
        case .favorites:return all.filter{library.favorites.contains($0.id)}
        case .home,.history:let lookup=Dictionary(all.map{($0.id,$0)},uniquingKeysWith:{a,_ in a}); return library.history.compactMap{lookup[$0]}
        case .search:return all
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
                                    .foregroundStyle(homeFocus == .nav(p) ? Color.black : page == p ? Color.cyan : Color.white)
                                    .background(RoundedRectangle(cornerRadius:10).fill(homeFocus == .nav(p) ? Color.white : page == p ? Color.cyan.opacity(0.12) : Color.clear))
                            }.buttonStyle(.plain).focused($homeFocus,equals:.nav(p))
                        }
                    }.onMoveCommand(perform: moveSidebar)
                    Spacer(minLength:0)
                    Text("v0.2.1").font(.system(size:19)).foregroundStyle(.secondary)
                }.padding(18).frame(width:300).frame(maxHeight:.infinity,alignment:.topLeading).focusSection().background(Color.white.opacity(0.045))
            }
            VStack(alignment:.leading,spacing:14) {
                if !expanded { HStack {Text(page.rawValue).font(.title.bold());Spacer();if library.busy {ProgressView()};Text("\(library.media.count) items").font(.caption).foregroundStyle(.secondary)} }
                if !library.message.isEmpty && !expanded {Text(library.message).font(.caption).foregroundStyle(.yellow)}
                if page == .settings {SettingsView(library:library,entryFocus:$homeFocus)}
                else if page == .sources {sourceView}
                else if page == .live {liveView}
                else if page == .guide {guideBrowser}
                else if page == .home {dashboard}
                else {browseView}
            }.padding(expanded ? 0 : 24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).focusSection()
        }.background(backgroundColor.ignoresSafeArea()).onExitCommand {if expanded {return} else if selected != nil {playback.stop();selected=nil} else {page = .home}}
        .fullScreenCover(item:$play){item in Playback(item:item,library:library)}
        .sheet(item:$details){item in SeriesView(item:item,library:library)}
        .sheet(item:$guideItem){item in GuideView(item:item,library:library)}
        .sheet(item:$editor){s in SourceEditor(library:library,source:s)}
        .sheet(isPresented:$add){SourceEditor(library:library,source:Source(name:"",address:"",type:"M3U URL"))}
        .alert("Remove source?",isPresented:Binding(get:{removeSource != nil},set:{if !$0 {removeSource=nil}})){Button("Remove",role:.destructive){if let s=removeSource{library.remove(s)};removeSource=nil};Button("Cancel",role:.cancel){removeSource=nil}}
    }
    private func openPage(_ p:Page,enter:Bool) {
        if p != page {playback.stop(); selected=nil; filter="All groups";sourceFilter="All sources";query="";page=p}
        if enter { Task { @MainActor in await Task.yield(); homeFocus = .content } }
    }
    private func moveSidebar(_ direction:MoveCommandDirection) {
        guard case let .nav(p)? = homeFocus, let i=Page.allCases.firstIndex(of:p) else{return}
        switch direction {
        case .right:openPage(p,enter:true)
        case .up:if i>0 {homeFocus = .nav(Page.allCases[i-1])}
        case .down:if i+1<Page.allCases.count {homeFocus = .nav(Page.allCases[i+1])}
        default:break
        }
    }
    private var backgroundColor:Color { appearance == "Black OLED" ? .black : Color(red:0.055,green:0.075,blue:0.12) }
    private func pageIcon(_ p:Page)->String { switch p {case .home:return "house";case .live:return "tv";case .guide:return "calendar";case .movies:return "film";case .series:return "play.rectangle.on.rectangle";case .favorites:return "star";case .history:return "clock";case .search:return "magnifyingglass";case .sources:return "list.bullet";case .settings:return "gearshape"} }
    private func selectChannel(_ item:Media) { selected=item;library.watched(item);playback.start(item) }
    private var channelFilters:some View {
        VStack(alignment:.leading,spacing:10) {
            Picker("Source",selection:$sourceFilter){Text("All sources").tag("All sources");ForEach(library.sources){s in Text(s.name).tag(s.id.uuidString)}}.font(.system(size:labelSize)).onChange(of:sourceFilter){_ in filter="All groups"}.focused($homeFocus,equals:.content)
            Text("Categories").font(.caption).foregroundStyle(.secondary)
            ScrollView {LazyVStack(alignment:.leading,spacing:12){ForEach(["All groups"]+groups,id:\.self){g in Button {filter=g} label:{Text(g).font(.system(size:labelSize)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(filter == g ? Color.cyan : Color.primary)}}.padding(8)}}
        }.frame(width:235).frame(maxHeight:.infinity,alignment:.top).focusSection()
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
                            ViewThatFits(in:.horizontal){Text(item.name).font(.system(size:labelSize)).fixedSize(horizontal:true,vertical:false);Text(item.name).font(.system(size:max(18,labelSize-4))).fixedSize(horizontal:true,vertical:false);Text(item.name).font(.system(size:max(18,labelSize-4))).lineLimit(nil).fixedSize(horizontal:false,vertical:true)}.layoutPriority(1).frame(maxWidth:.infinity,alignment:.leading)
                            if library.favorites.contains(item.id){Image(systemName:"star.fill").font(.system(size:19)).foregroundStyle(.yellow)}
                        }.foregroundStyle(selected?.id == item.id ? Color.cyan : Color.primary).padding(.vertical,3).frame(maxWidth:.infinity,alignment:.leading)}.focused($homeFocus,equals:.channel(item.id)).contextMenu{Button(library.favorites.contains(item.id) ? "Remove favorite" : "Add favorite"){library.toggle(item)}}
                    }}.padding(8)}
                }.frame(width:465).frame(maxHeight:.infinity,alignment:.top).focusSection()
            }
            VStack(alignment:.leading,spacing:12) {
                if let item=selected {
                    if expanded {
                        FullPlayer(item:item,session:playback,library:library,channels:shown,onSelect:{selectChannel($0)},onClose:{expanded=false;Task{@MainActor in await Task.yield();homeFocus = .channel(item.id)}})
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
        let programmes=library.guide.filter{library.guideSource==item.sourceID && $0.channel==item.tvg && $0.end>Date()}.sorted{$0.start<$1.start}
        return VStack(alignment:.leading,spacing:10){HStack{Text("Programme guide").font(.headline);Spacer();Button("Load guide"){if let s=library.sources.first(where:{$0.id==item.sourceID}){Task{await library.loadGuide(s)}}}.font(.caption2).disabled(library.busy)};if programmes.isEmpty{Text("No programme data. Add an XMLTV URL in Playlists.").font(.caption).foregroundStyle(.secondary)}else{ScrollView(.horizontal){HStack{ForEach(Array(programmes.prefix(12))){p in VStack(alignment:.leading){Text(p.start.formatted(date:.omitted,time:.shortened));Text(p.title).lineLimit(2)}.font(.caption2).padding(10).frame(width:240,height:90,alignment:.topLeading).background(p.start<=Date() ? Color.blue.opacity(0.45) : Color.white.opacity(0.08))}}}}}
    }
    private var guideBrowser:some View {HStack(alignment:.top,spacing:22){channelFilters;ScrollView{LazyVStack(alignment:.leading,spacing:14){ForEach(shown){item in Button{guideItem=item}label:{HStack{Text(item.name).frame(width:360,alignment:.leading);Text(library.guide.first{library.guideSource==item.sourceID && $0.channel==item.tvg && $0.start<=Date() && $0.end>Date()}?.title ?? "No programme data").foregroundStyle(.secondary);Spacer()}.font(.caption)}}.padding(12)}}}}
    private var dashboard:some View {ScrollView{VStack(alignment:.leading,spacing:25){if library.sources.isEmpty{Text("Add your first playlist").font(.title2);Button("Add playlist"){add=true}.focused($homeFocus,equals:.content)}else{HStack{Button{openPage(.live,enter:true)}label:{Label("Live TV",systemImage:"tv")}.focused($homeFocus,equals:.content);ForEach([Page.movies,.series,.sources],id:\.self){p in Button{openPage(p,enter:true)}label:{Label(p.rawValue,systemImage:pageIcon(p))}}};dashboardRow("Recently viewed",base);dashboardRow("Favorites",library.media.filter{library.favorites.contains($0.id)});dashboardRow("Movies",library.media.filter{$0.kind == .movie});dashboardRow("Series",library.media.filter{$0.kind == .series})}}}}
    private func dashboardRow(_ title:String,_ items:[Media])->some View {VStack(alignment:.leading,spacing:10){Text(title).font(.title3.bold());if items.isEmpty{Text("Nothing here yet").font(.caption).foregroundStyle(.secondary)}else{ScrollView(.horizontal){HStack(spacing:25){ForEach(Array(items.prefix(20))){item in Button{if item.kind == .series{details=item}else if item.kind == .live{page = .live;selectChannel(item)}else{library.watched(item);play=item}}label:{MediaTile(item:item,favorite:library.favorites.contains(item.id)).frame(width:230)}.buttonStyle(.card)}}.padding(16)}}}}
    private var browseView:some View {
        HStack(alignment:.top,spacing:30){
            VStack(alignment:.leading,spacing:10){
                Text("Sources").font(.caption).foregroundStyle(.secondary)
                Picker("Source",selection:$sourceFilter){Text("All sources").tag("All sources");ForEach(library.sources){s in Text(s.name).tag(s.id.uuidString)}}.onChange(of:sourceFilter){_ in filter="All groups"}
                Text("Categories").font(.caption).foregroundStyle(.secondary)
                ScrollView {LazyVStack(alignment:.leading,spacing:12){ForEach(["All groups"]+groups,id:\.self){g in Button {filter=g} label:{Text(g).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(filter == g ? Color.cyan : Color.primary)}}}}
            }.frame(width:365)
            VStack(alignment:.leading,spacing:14){
                HStack {Text(page == .home ? "Recently watched" : page.rawValue).font(.title2.bold());Spacer();Text("\(shown.count)").foregroundStyle(.secondary)}
                TextField("Search channels, movies or series",text:$query).focused($homeFocus,equals:.content)
                if shown.isEmpty {Text("No items in this view.").foregroundStyle(.secondary);Spacer()}
                else {ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:240),spacing:22)],spacing:35){ForEach(shown){item in
                    Button {if item.kind == .series {details=item} else if item.kind == .live {page = .live;filter="All groups";sourceFilter="All sources";query="";selectChannel(item)} else {library.watched(item);play=item}} label:{MediaTile(item:item,favorite:library.favorites.contains(item.id))}
                        .buttonStyle(.card)
                        .contextMenu {Button(library.favorites.contains(item.id) ? "Remove favorite" : "Add favorite"){library.toggle(item)};if item.kind == .live {Button("Programme guide"){guideItem=item}}}
                }}}}
            }.frame(maxWidth:.infinity)
        }
    }
    private var sourceView:some View {
        VStack(alignment:.leading,spacing:20){Button{add=true}label:{Label("Add source",systemImage:"plus")}.focused($homeFocus,equals:.content).disabled(library.busy)
            ScrollView {LazyVStack(alignment:.leading,spacing:25){ForEach(library.sources){s in HStack{VStack(alignment:.leading){Text(s.name).font(.headline);Text(s.type+" · \(library.media.filter{$0.sourceID==s.id}.count) items").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Refresh"){Task{_ = await library.load(s)}}.disabled(library.busy);Button("EPG"){Task{await library.loadGuide(s)}}.disabled(library.busy);Button("Edit"){editor=s}.disabled(library.busy);Button("Remove"){removeSource=s}.disabled(library.busy)}}}}
        }.frame(maxHeight:.infinity,alignment:.topLeading)
    }
}
struct MediaTile:View {
    var item:Media; var favorite:Bool
    var body:some View {VStack(alignment:.leading,spacing:8){
        ZStack{RoundedRectangle(cornerRadius:12).fill(Color.white.opacity(0.09));if let url=httpURL(item.logo){AsyncImage(url:url){image in image.resizable().scaledToFit()} placeholder:{Image(systemName:icon).font(.largeTitle).foregroundStyle(.secondary)}}else{Image(systemName:icon).font(.largeTitle).foregroundStyle(.secondary)}}.frame(height:135).clipped()
        HStack{Text(item.name).font(.system(size:24,weight:.medium)).lineLimit(nil).fixedSize(horizontal:false,vertical:true);Spacer(minLength:0);if favorite{Image(systemName:"star.fill").foregroundStyle(.yellow).font(.caption)}}
        Text(item.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }.padding(10).frame(maxWidth:.infinity,alignment:.leading)}
    var icon:String {item.kind == .live ? "tv" : (item.kind == .movie ? "film" : "play.rectangle.on.rectangle")}
}
struct SourceEditor:View {
    @ObservedObject var library:Library
    @State var source:Source
    @Environment(\.dismiss) private var dismiss
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:24){
        Text("Playlist / account").font(.title.bold())
        Picker("Source type",selection:$source.type){ForEach(["M3U URL","Pasted M3U","Xtream"],id:\.self){Text($0).tag($0)}}.disabled(library.busy)
        TextField("Display name",text:$source.name)
        if source.type == "Pasted M3U" {TextField("Paste M3U text using Apple TV keyboard",text:$source.pasted)} else {TextField(source.type == "Xtream" ? "Server URL (https://host:port)" : "Playlist URL",text:$source.address)}
        if source.type == "Xtream" {TextField("Username",text:$source.user);SecureField("Password",text:$source.password)}
        TextField("XMLTV guide URL (optional)",text:$source.epg)
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
    let item:Media; @ObservedObject var library:Library; @Environment(\.dismiss) private var dismiss
    var body:some View{VStack(alignment:.leading,spacing:24){HStack{Text(item.name).font(.title.bold());Spacer();Button("Close"){dismiss()}};Button("Load XMLTV guide"){if let s=library.sources.first(where:{$0.id==item.sourceID}){Task{await library.loadGuide(s)}}}.disabled(library.busy);if library.busy{ProgressView()};Text(library.message).font(.caption);ScrollView{LazyVStack(alignment:.leading){ForEach(library.guide.filter{library.guideSource == item.sourceID && $0.channel==item.tvg && $0.end>Date()}.sorted{$0.start<$1.start}){p in HStack{Text(p.start.formatted(date:.abbreviated,time:.shortened)).foregroundStyle(.secondary);Text(p.title).font(.headline)}}}}}.padding(65)}
}
