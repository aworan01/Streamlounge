import SwiftUI

struct GuideTimeline: View {
    let items:[Media];@ObservedObject var library:Library;let play:(Media)->Void;let details:(Media)->Void
    @State private var hourOffset=0
    @State private var clock=Date()
    @State private var search=""
    private let window:TimeInterval=3*3600
    private var start:Date {Date(timeIntervalSince1970:floor(clock.timeIntervalSince1970/1800)*1800+Double(hourOffset)*3600)}
    private var visible:[Media]{search.isEmpty ? items : items.filter{$0.name.localizedCaseInsensitiveContains(search)}}
    var body:some View {
        VStack(alignment:.leading,spacing:12){
            HStack{Button("Now"){hourOffset=0};Button{hourOffset=max(-24,hourOffset-3)}label:{Image(systemName:"chevron.left")};Button{hourOffset=min(24*14,hourOffset+3)}label:{Image(systemName:"chevron.right")};Text(start.formatted(date:.abbreviated,time:.shortened)).font(.caption);Spacer();Button("Refresh all"){Task{await library.refreshAllGuides(force:true)}}.disabled(library.epgBusy)}.font(.system(size:22))
            TextField("Search guide channels",text:$search).font(.system(size:22))
            if library.epgBusy{ProgressView()};if !library.epgStatus.isEmpty{Text(library.epgStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)}
            GeometryReader{geo in
                let channelWidth=min(300,max(210,geo.size.width*0.25));let timelineWidth=max(200,geo.size.width-channelWidth-24)
                VStack(alignment:.leading,spacing:4){
                    HStack(spacing:8){Text("Channel").font(.caption).frame(width:channelWidth,alignment:.leading);ZStack(alignment:.leading){ForEach(0..<6,id:\.self){i in Text(start.addingTimeInterval(Double(i)*1800).formatted(date:.omitted,time:.shortened)).font(.system(size:17)).foregroundStyle(.secondary).offset(x:CGFloat(i)*timelineWidth/6)}}.frame(width:timelineWidth,height:30,alignment:.leading).clipped()}
                    ScrollView{LazyVStack(alignment:.leading,spacing:5){ForEach(visible){item in
                        HStack(spacing:8) {
                            Button {play(item)} label: {
                                HStack(spacing:6) {
                                    Image(systemName:"play.fill").font(.system(size:15))
                                    Text(item.name).font(.system(size:20)).lineLimit(2).minimumScaleFactor(0.7)
                                }.frame(width:channelWidth,height:65,alignment:.leading)
                            }.accessibilityLabel("Watch " + item.name)
                            Button {details(item)} label: {schedule(item,width:timelineWidth)}
                                .accessibilityLabel("Programme details for " + item.name)
                        }
                        .buttonStyle(CompactFocusStyle(inset:3))
                    }}}
                }
            }
        }.task {while !Task.isCancelled{try? await Task.sleep(nanoseconds:30_000_000_000);if !Task.isCancelled{clock=Date()}}}
    }
    private func schedule(_ item:Media,width:CGFloat)->some View {
        let end=start.addingTimeInterval(window)
        let events=library.programmes(item).filter{$0.start<end && $0.end>start}
        return ZStack(alignment:.leading){
            RoundedRectangle(cornerRadius:5).fill(Color.white.opacity(0.04))
            if events.isEmpty {Text("No programme data").font(.system(size:17)).foregroundStyle(.secondary).padding(8)}
            ForEach(events){p in
                let x=CGFloat(max(0,p.start.timeIntervalSince(start))/window)*width
                let w=CGFloat(min(end,p.end).timeIntervalSince(max(start,p.start))/window)*width
                Text(p.title).font(.system(size:18)).lineLimit(2).padding(.horizontal,6).frame(width:max(1,w-2),height:61,alignment:.leading).clipped().background(p.start<=clock && p.end>clock ? Color.cyan.opacity(0.28):Color.white.opacity(0.10),in:RoundedRectangle(cornerRadius:5)).offset(x:x)
            }
            if clock>=start && clock<end{Rectangle().fill(Color.cyan).frame(width:2,height:65).offset(x:CGFloat(clock.timeIntervalSince(start)/window)*width)}
        }.frame(width:width,height:65,alignment:.leading).clipped()
    }
}
