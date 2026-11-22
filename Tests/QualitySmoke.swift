import Foundation
@main struct QualitySmoke {
    static func main() {
        precondition(qualityTier(width:0,height:0)=="—")
        precondition(qualityTier(width:720,height:576)=="SD")
        precondition(qualityTier(width:1280,height:720)=="HD")
        precondition(qualityTier(width:1920,height:1080)=="FHD")
        precondition(qualityTier(width:3840,height:2160)=="4K")
        precondition(qualityTier(width:4096,height:2160)=="4K")
        precondition(qualityTier(width:.nan,height:1080)=="—")
        print("PASS: SD, HD, FHD, 4K and unknown/unavailable decoder resolutions.")
    }
}
