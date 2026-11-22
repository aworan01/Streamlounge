import SwiftUI

struct SettingsView:View {
    @ObservedObject var library:Library
    var entryFocus:FocusState<HomeFocus?>.Binding
    @AppStorage("textDensity") private var textDensity="Compact"
    private let sections=["Playback","Appearance","EPG / TV Guide","Data management","About"]
    private func enter(_ name:String){section=name;Task{@MainActor in await Task.yield();entryFocus.wrappedValue = .settingsOption}}
    @AppStorage("engine") private var engine="Auto"
    @AppStorage("hardware") private var hardware=true
    @AppStorage("bufferSeconds") private var buffer:Double=5
    @AppStorage("appearance") private var appearance="Night Owl"
    @State private var section="Playback"
    @State private var clearHistory=false
    var body:some View {
        HStack(alignment:.top,spacing:40){
            VStack(alignment:.leading,spacing:12){ForEach(sections,id:\.self){name in Button{enter(name)}label:{Text(name).font(.system(size:25)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(section == name ? Color.cyan : Color.primary)}.focused(entryFocus,equals:name == "Playback" ? .content : .settingsSection(name))}}.frame(width:350).frame(maxHeight:.infinity,alignment:.topLeading).focusSection().onMoveCommand{direction in
                let focusedName:String
                switch entryFocus.wrappedValue {case .content?:focusedName="Playback";case .settingsSection(let name)?:focusedName=name;default:return}
                guard let i=sections.firstIndex(of:focusedName) else{return}
                switch direction {case .right:enter(focusedName);case .left:entryFocus.wrappedValue = .nav(.settings);case .up:if i>0 {entryFocus.wrappedValue = i==1 ? .content : .settingsSection(sections[i-1])};case .down:if i+1<sections.count {entryFocus.wrappedValue = .settingsSection(sections[i+1])};default:break}
            }
            ScrollView { VStack(alignment:.leading,spacing:26){Text(section).font(.title2.bold())
                switch section {
                case "Playback":
                    Picker("Player engine",selection:$engine){ForEach(["Auto","AVPlayer","VLC"],id:\.self){Text($0).tag($0)}}.focused(entryFocus,equals:.settingsOption)
                    Text("Auto selects VLC for named 4K/UHD streams or MKV, and falls back to VLC if AVPlayer fails to display video within 15 seconds. Manual selection overrides this.").font(.caption).foregroundStyle(.secondary)
                    Toggle("VLC hardware decoding",isOn:$hardware)
                    Text("If a UHD stream has sound but no picture, try disabling VLC hardware decoding and reopening it. Software decoding may be too demanding for some Apple TVs.").font(.caption).foregroundStyle(.secondary)
                    Picker("Buffer duration",selection:$buffer){ForEach([2.0,5.0,10.0,20.0],id:\.self){Text("\(Int($0)) seconds").tag($0)}}
                    Text("Original resolution; the player does not request downscaling. Preferences apply when a stream is reopened. AVPlayer and VLC may choose variants according to their own policies.").font(.caption).foregroundStyle(.secondary)
                case "Appearance":Picker("Theme",selection:$appearance){ForEach(["Night Owl","Black OLED"],id:\.self){Text($0).tag($0)}}.focused(entryFocus,equals:.settingsOption)
                    Picker("Text size",selection:$textDensity){ForEach(["Compact","Standard","Large"],id:\.self){Text($0).tag($0)}}
                    Text("Compact reduces sidebar and live channel text. Long channel names wrap instead of being cut off.").font(.caption).foregroundStyle(.secondary)
                case "EPG / TV Guide":
                    EPGSettingsPanel(library:library,entryFocus:entryFocus)
                case "Data management":Button("Clear viewing history"){clearHistory=true}.focused(entryFocus,equals:.settingsOption);Text("Playlists and favorites are retained. Catalogs are stored in tvOS cache and may need refreshing after system cleanup.").font(.caption).foregroundStyle(.secondary)
                default:Button("Back to settings categories"){entryFocus.wrappedValue = .settingsSection(section)}.focused(entryFocus,equals:.settingsOption);Text("Stream Lounge TV v0.2.4");Text("Independent tvOS adaptation of selected IPTVnator v0.25.0 functionality. IPTVnator code: MIT, 4gray. VideoLAN TVVLCKit 3.7.3: LGPL 2.1. Use only authorized streams.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16) }.frame(maxHeight:.infinity,alignment:.topLeading).focusSection()
        }.alert("Clear viewing history?",isPresented:$clearHistory){Button("Clear",role:.destructive){library.history=[];library.save()};Button("Cancel",role:.cancel){}}
    }
}

struct EPGSettingsPanel:View {
    @ObservedObject var library:Library
    var entryFocus:FocusState<HomeFocus?>.Binding
    @AppStorage("epgExternal") private var external=true
    @AppStorage("epgProvider") private var provider=true
    @AppStorage("epgCustom") private var custom=true
    @AppStorage("epgOrder") private var order="Provider first"
    @AppStorage("epgCountries") private var countries=""
    @AppStorage("epgInterval") private var interval=12
    @AppStorage("epgOnStart") private var onStart=true
    @AppStorage("epgOnImport") private var onImport=true
    @AppStorage("epgDays") private var days=7
    @AppStorage("epgPast") private var past=1
    @AppStorage("epgOffset") private var offset=0
    @AppStorage("epgBorrow") private var borrow=true
    @State private var clear=false
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            Button("Update all guides now"){Task{await library.refreshAllGuides(force:true)}}.focused(entryFocus,equals:.settingsOption).disabled(library.epgBusy)
            if library.epgBusy{ProgressView()};Text(library.epgStatus).font(.caption).foregroundStyle(.secondary)
            Toggle("Provider EPG",isOn:$provider);Toggle("Custom XMLTV",isOn:$custom);Toggle("Automatic EPGShare01",isOn:$external)
            TextField("Country codes (blank = automatic)",text:$countries)
            Text("Examples: UK, US, NG, ZA. Playlist-specific country settings override this list. Coverage varies by source.").font(.caption).foregroundStyle(.secondary)
            Picker("Source priority",selection:$order){ForEach(["Provider first","Custom first","External first"],id:\.self){Text($0).tag($0)}}
            Toggle("Borrow guide from equivalent channels",isOn:$borrow)
            Picker("Refresh every",selection:$interval){ForEach([3,6,12,24,48],id:\.self){Text("\($0) hours").tag($0)}}
            Toggle("Refresh on app launch",isOn:$onStart);Toggle("Refresh after playlist import",isOn:$onImport)
            Picker("Days ahead",selection:$days){ForEach(1...14,id:\.self){Text("\($0) days").tag($0)}}
            Picker("Past days",selection:$past){ForEach(0...7,id:\.self){Text("\($0) days").tag($0)}}
            Picker("Global time correction",selection:$offset){ForEach(Array(stride(from:-720,through:720,by:15)),id:\.self){Text("\($0) min").tag($0)}}
            Text("Refresh runs while the app is active; tvOS may suspend it in the background. Time correction and source changes apply at the next update.").font(.caption).foregroundStyle(.secondary)
            Text("EPG sources and statistics").font(.headline)
            ForEach(library.sources){source in
                VStack(alignment:.leading,spacing:6){
                    HStack{Text(source.name).font(.headline);Spacer();Button("Refresh"){Task{await library.loadGuide(source)}}.disabled(library.epgBusy)}
                    Text("Provider: \(providerGuideURLs(source).count) · Custom: \(source.epg.components(separatedBy:.whitespacesAndNewlines).compactMap(httpURL).count) · Countries: \(guideCountries(source,library.media.filter{$0.sourceID==source.id && $0.kind == .live},GuideOptions.read()).joined(separator:", "))").font(.caption2).foregroundStyle(.secondary)
                    if let snapshot=library.guides[source.id]{Text("Matched \(snapshot.matched) / \(snapshot.total) · \(snapshot.feeds) feeds · \(snapshot.failures) failures").font(.caption);Text("Updated "+snapshot.updated.formatted()).font(.caption2).foregroundStyle(.secondary);ForEach(Array(snapshot.status.enumerated()),id:\.offset){entry in Text(entry.element).font(.caption2).foregroundStyle(.secondary)}}else{Text("No cached EPG yet").font(.caption).foregroundStyle(.secondary)}
                }.padding(10).background(Color.white.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
            }
            Button("Clear guide cache"){clear=true}.disabled(library.epgBusy)
            Text("Custom sources and country overrides: Playlists → Edit. Manual XMLTV ID: TV Guide → select a channel.").font(.caption).foregroundStyle(.secondary)
        }.alert("Clear downloaded programme guides?",isPresented:$clear){Button("Clear",role:.destructive){library.clearGuides()};Button("Cancel",role:.cancel){}}
    }
}
