import Foundation

@main struct Regression {
    static func main() {
        let s=Source(name:"Unit",address:"https://example.invalid/list.m3u",type:"M3U URL")
        let playlist="""
        #EXTM3U
        #EXTINF:-1 tvg-id="bbc-one" group-title="UK",BBC One UHD
        https://example.invalid/live/playlist/first.m3u8
        #EXTINF:-1 tvg-id="movies" group-title="Cinema",Example Movie
        https://example.invalid/movie/username/password/151.mp4
        """
        let items=parseM3U(playlist,source:s)
        precondition(items.count==2,"M3U parsing failed")
        precondition(items[0].kind == .live && items[0].tvg == "bbc-one")
        precondition(items[1].kind == .movie)
        precondition(qualityTier(width:3840,height:2160)=="4K")
        precondition(qualityTier(width:1920,height:1080)=="FHD")
        precondition(qualityTier(width:1280,height:720)=="HD")
        precondition(qualityTier(width:640,height:480)=="SD")
        let progress=PlaybackBookmark(seconds:180,duration:3600,updated:Date(),completed:false)
        precondition(playbackResumeTime(progress)==180)
        precondition(playbackResumeTime(PlaybackBookmark(seconds:3550,duration:3600,updated:Date(),completed:true))==0)
        precondition(formatPlaybackTime(3754)=="1:02:34")
        print("PASS: M3U parse, movie detection, 4K tiers, resume bounds, time formatting")
    }
}
