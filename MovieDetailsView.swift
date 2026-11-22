import SwiftUI

struct MovieDetailsView:View {
    let item:Media
    @ObservedObject var library:Library
    @Environment(\.dismiss) private var dismiss
    @State private var showPlayer=false
    private var info:MovieInformation? {library.movieInformation(for:item)}
    private var bookmark:PlaybackBookmark? {library.bookmark(for:item)}
    private var poster:String {info?.poster.isEmpty == false ? (info?.poster ?? "") : item.logo}
    var body:some View {
        ScrollView {
            HStack(alignment:.top,spacing:40) {
                ZStack {
                    RoundedRectangle(cornerRadius:12).fill(Color.white.opacity(0.10))
                    if let url=httpURL(poster) {AsyncImage(url:url){i in i.resizable().scaledToFit()}placeholder:{Image(systemName:"film").font(.largeTitle)}}
                    else {Image(systemName:"film").font(.largeTitle)}
                }.frame(width:320,height:460)
                VStack(alignment:.leading,spacing:22) {
                    Text(item.name).font(.system(size:46,weight:.bold)).fixedSize(horizontal:false,vertical:true)
                    Text(([info?.year,info?.genre,info?.duration,info?.rating].compactMap{$0}.filter{!$0.isEmpty}).joined(separator:" • ")).foregroundStyle(.secondary)
                    if let text=info?.synopsis,!text.isEmpty {Text(text).font(.system(size:24)).fixedSize(horizontal:false,vertical:true)}
                    else {Text("No description was provided by this source.").foregroundStyle(.secondary)}
                    if let cast=info?.credits,!cast.isEmpty {Text("Cast: "+cast).font(.caption).foregroundStyle(.secondary)}
                    if let b=bookmark,b.seconds>=30,!b.completed {
                        Text("Saved position: "+formatPlaybackTime(Int(b.seconds))).foregroundStyle(.cyan)
                        ProgressView(value:b.progress).frame(maxWidth:500)
                    }
                    HStack(spacing:20){
                        Button(playbackResumeTime(bookmark)>0 ? "Resume movie" : "Play movie"){library.watched(item);showPlayer=true}
                        if playbackResumeTime(bookmark)>0 {Button("Restart") {library.clearProgress(item);library.watched(item);showPlayer=true}}
                        Button(library.favorites.contains(item.id) ? "Remove favourite" : "Favourite") {library.toggle(item)}
                        Button("Close"){dismiss()}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding(55)
        }
        .task {await library.loadMovieInformation(item)}
        .fullScreenCover(isPresented:$showPlayer){Playback(item:item,library:library)}
    }
}
