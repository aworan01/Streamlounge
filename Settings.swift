import SwiftUI

struct SettingsView:View {
    @ObservedObject var library:Library
    @AppStorage("engine") private var engine="Auto"
    @AppStorage("hardware") private var hardware=true
    @AppStorage("bufferSeconds") private var buffer:Double=5
    @AppStorage("appearance") private var appearance="Night Owl"
    @State private var section="Playback"
    @State private var clearHistory=false
    var body:some View {
        HStack(alignment:.top,spacing:40){
            VStack(alignment:.leading,spacing:18){ForEach(["Playback","Appearance","EPG / TV Guide","Data management","About"],id:\.self){name in Button{section=name}label:{Text(name).frame(maxWidth:.infinity,alignment:.leading).foregroundStyle(section == name ? Color.cyan : Color.primary)}}}.frame(width:400)
            ScrollView { VStack(alignment:.leading,spacing:26){Text(section).font(.title2.bold())
                switch section {
                case "Playback":
                    Picker("Player engine",selection:$engine){ForEach(["Auto","AVPlayer","VLC"],id:\.self){Text($0).tag($0)}}
                    Text("Auto selects VLC for named 4K/UHD streams or MKV, and falls back to VLC if AVPlayer fails to display video within 15 seconds. Manual selection overrides this.").font(.caption).foregroundStyle(.secondary)
                    Toggle("VLC hardware decoding",isOn:$hardware)
                    Text("If a UHD stream has sound but no picture, try disabling VLC hardware decoding and reopening it. Software decoding may be too demanding for some Apple TVs.").font(.caption).foregroundStyle(.secondary)
                    Picker("Buffer duration",selection:$buffer){ForEach([2.0,5.0,10.0,20.0],id:\.self){Text("\(Int($0)) seconds").tag($0)}}
                    Text("Original resolution; the player does not request downscaling. Preferences apply when a stream is reopened. AVPlayer and VLC may choose variants according to their own policies.").font(.caption).foregroundStyle(.secondary)
                case "Appearance":Picker("Theme",selection:$appearance){ForEach(["Night Owl","Black OLED"],id:\.self){Text($0).tag($0)}}
                case "EPG / TV Guide":
                    Text("Set XMLTV URLs per playlist in Playlists → Edit. Import uncompressed XMLTV here.").font(.caption).foregroundStyle(.secondary)
                    ForEach(library.sources){source in Button("Refresh \(source.name)"){Task{await library.loadGuide(source)}}.disabled(library.busy)}
                case "Data management":Button("Clear viewing history"){clearHistory=true};Text("Playlists and favorites are retained. Catalogs are stored in tvOS cache and may need refreshing after system cleanup.").font(.caption).foregroundStyle(.secondary)
                default:Text("Stream Lounge TV v0.2.0");Text("Independent tvOS adaptation of selected IPTVnator v0.25.0 functionality. IPTVnator code: MIT, 4gray. VideoLAN TVVLCKit 3.7.3: LGPL 2.1. Use only authorized streams.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading).padding(16) }
        }.alert("Clear viewing history?",isPresented:$clearHistory){Button("Clear",role:.destructive){library.history=[];library.save()};Button("Cancel",role:.cancel){}}
    }
}
