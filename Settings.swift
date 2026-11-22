import SwiftUI

struct SettingsView:View {
    @ObservedObject var library:Library
    var entryFocus:FocusState<HomeFocus?>.Binding
    @AppStorage("textDensity") private var textDensity="Compact"
    private let sections=["Playback","ClearKey","Appearance","Dashboard","EPG / TV Guide","Data management","About"]
    private func enter(_ name:String){section=name;Task{@MainActor in await Task.yield();entryFocus.wrappedValue = .settingsOption}}
    @AppStorage("engine") private var engine="Auto"
    @AppStorage("hardware") private var hardware=true
    @AppStorage("ksDecoder") private var ksDecoder="Native first"
    @AppStorage("bufferSeconds") private var buffer:Double=5
    @AppStorage("appearance") private var appearance="Night Owl"
    @AppStorage("startPage") private var startPage="Dashboard"
    @AppStorage("rememberLastChannel") private var rememberLastChannel=true
    @AppStorage("autoRefreshPlaylists") private var autoRefreshPlaylists=false
    @State private var section="Playback"
    @State private var clearHistory=false
    var body:some View {
        HStack(alignment:.top,spacing:40){
            VStack(alignment:.leading,spacing:12){ForEach(sections,id:\.self){name in Button{enter(name)}label:{Text(name).font(.system(size:25)).lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(section == name ? Color.cyan : Color.primary)}.focused(entryFocus,equals:name == "Playback" ? .content : .settingsSection(name))}}.frame(width:350).frame(maxHeight:.infinity,alignment:.topLeading).focusSection().onMoveCommand{direction in
                let focusedName:String
                switch entryFocus.wrappedValue {case .content?:focusedName="Playback";case .settingsSection(let name)?:focusedName=name;default:return}
                // Let tvOS move focus vertically: manual Up/Down here competed
                // with the focus engine and could skip entire rows.
                switch direction {
                case .right:enter(focusedName)
                case .left:entryFocus.wrappedValue = .nav(.settings)
                default:break
                }
            }
            ScrollView { VStack(alignment:.leading,spacing:26){Text(section).font(.title2.bold())
                switch section {
                case "Playback":
                    ConfirmSelection(title: "Player engine", selection: $engine, options: [
                        ConfirmOption("Auto", "Auto"), ConfirmOption("AVPlayer", "AVPlayer"),
                        ConfirmOption("VLC", "VLC"), ConfirmOption("KSPlayer", "KSPlayer")
                     ])
                    .onAppear {
                        #if !canImport(KSPlayerUI)
                        if engine == "KSPlayer" {engine="Auto"}
                        #endif
                    }
                    Text("Auto starts 4K/HDR HLS streams with the native AVPlayer decoder; VLC is reserved for incompatible containers or as fallback. If a stream crashed recently, native recovery mode is selected next launch.").font(.caption).foregroundStyle(.secondary)
                    #if canImport(KSPlayerUI) && canImport(KSPlayer)
                    ConfirmSelection(title: "KSPlayer decoder", selection: $ksDecoder, options: [
                        ConfirmOption("Native first", "Native first"),
                        ConfirmOption("FFmpeg first", "FFmpeg first")
                    ])
                    Text("KSPlayer 5.6.2 normally starts with native decoding. FFmpeg first may help HEVC in unusual IPTV containers, but some 4K formats may still exceed Apple TV decoder support. Reopen the stream after changing this option.").font(.caption).foregroundStyle(.secondary)
                    #endif
                    Toggle("VLC hardware decoding",isOn:$hardware)
                    Text("If a UHD stream has sound but no picture, try disabling VLC hardware decoding and reopening it. Software decoding may be too demanding for some Apple TVs.").font(.caption).foregroundStyle(.secondary)
                    ConfirmSelection(title: "Buffer duration", selection: $buffer, options: [2.0,5.0,10.0,20.0].map { ConfirmOption($0, "\(Int($0)) seconds") })
                    Text("Original resolution; the player does not request downscaling. Preferences apply when a stream is reopened. AVPlayer and VLC may choose variants according to their own policies.").font(.caption).foregroundStyle(.secondary)
                case "ClearKey":
                    ClearKeySettingsPanel(entryFocus:entryFocus)
                case "Appearance":ConfirmSelection(title: "Theme", selection: $appearance, options: ["Night Owl", "Black OLED"].map { ConfirmOption($0, $0) })
                    ConfirmSelection(title: "Text size", selection: $textDensity, options: ["Compact", "Standard", "Large"].map { ConfirmOption($0, $0) })
                    Text("Compact reduces sidebar and live channel text. Long channel names wrap instead of being cut off.").font(.caption).foregroundStyle(.secondary)
                case "Dashboard":
                    ConfirmSelection(title: "Start page", selection: $startPage, options: ["Dashboard","Live TV","Movies","Series","Favorites"].map { ConfirmOption($0, $0) })
                    Toggle("Remember last channel",isOn:$rememberLastChannel)
                    Toggle("Refresh playlists when app launches",isOn:$autoRefreshPlaylists)
                    Text("Automatic refresh uses the current playlist URL and retains existing favorite IDs when the source entries remain identical.").font(.caption).foregroundStyle(.secondary)
                case "EPG / TV Guide":
                    EPGSettingsPanel(library:library,entryFocus:entryFocus)
                case "Data management":Button("Clear viewing history"){clearHistory=true}.focused(entryFocus,equals:.settingsOption);Button("Clear watch progress"){library.forgetProgress()};Text("Playlists and favorites are retained. Watch progress and metadata are stored locally.").font(.caption).foregroundStyle(.secondary)
                default:Button("Back to settings categories"){entryFocus.wrappedValue = .settingsSection(section)}.focused(entryFocus,equals:.settingsOption);Text("Stream Lounge TV v0.3.4");Text("Independent tvOS adaptation of selected IPTVnator v0.25.0 functionality. IPTVnator code: MIT, 4gray. VideoLAN TVVLCKit 3.7.3: LGPL 2.1. KSPlayer 5.6.2: GPL-3.0. Use only authorized streams.").font(.caption).foregroundStyle(.secondary)
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
            ConfirmSelection(title: "Source priority", selection: $order, options: ["Provider first","Custom first","External first"].map { ConfirmOption($0, $0) })
            Toggle("Borrow guide from equivalent channels",isOn:$borrow)
            ConfirmSelection(title: "Refresh every", selection: $interval, options: [3,6,12,24,48].map { ConfirmOption($0, "\($0) hours") })
            Toggle("Refresh on app launch",isOn:$onStart);Toggle("Refresh after playlist import",isOn:$onImport)
            ConfirmSelection(title: "Days ahead", selection: $days, options: Array(1...14).map { ConfirmOption($0, "\($0) days") })
            ConfirmSelection(title: "Past days", selection: $past, options: Array(0...7).map { ConfirmOption($0, "\($0) days") })
            ConfirmSelection(title: "Global time correction", selection: $offset, options: Array(stride(from: -720, through: 720, by: 15)).map { ConfirmOption($0, "\($0) min") })
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
