import Foundation

// Local-only VOD progress. No cloud account and no external analytics.
struct PlaybackBookmark: Codable, Equatable {
    var seconds: Double
    var duration: Double
    var updated: Date
    var completed: Bool
    var progress: Double { duration > 0 ? min(1, max(0, seconds/duration)) : 0 }
}

struct MovieInformation: Codable {
    var synopsis: String = ""
    var genre: String = ""
    var year: String = ""
    var duration: String = ""
    var rating: String = ""
    var poster: String = ""
    var backdrop: String = ""
    var credits: String = ""
}

// Existing Xtream movie catalogue is used only for metadata; no new account
// types, portal protocols, or Xtream content categories are introduced here.
func fetchMovieInformation(source: Source, item: Media) async -> MovieInformation? {
    guard source.type == "Xtream", item.kind == .movie, !item.remoteID.isEmpty else { return nil }
    guard let payload = try? await Xtream(source: source).api("get_vod_info", extra: [URLQueryItem(name:"vod_id",value:item.remoteID)]) as? [String:Any] else { return nil }
    let data = payload["info"] as? [String:Any] ?? payload
    let details = payload["movie_data"] as? [String:Any] ?? [:]
    let genres = data["genre"] as? String ?? data["genres"] as? String ?? ""
    return MovieInformation(
        synopsis: str(data["plot"]).isEmpty ? str(data["description"]) : str(data["plot"]),
        genre: genres,
        year: str(data["releasedate"]).isEmpty ? str(data["year"]) : str(data["releasedate"]),
        duration: str(data["duration"]),
        rating: str(data["rating"]),
        poster: str(data["movie_image"]).isEmpty ? str(details["stream_icon"]) : str(data["movie_image"]),
        backdrop: str(data["backdrop_path"]),
        credits: str(data["cast"])
    )
}

func playbackResumeTime(_ bookmark: PlaybackBookmark?) -> Double {
    guard let b=bookmark, !b.completed, b.seconds >= 30, b.duration > 0,
          b.seconds < b.duration * 0.95 else { return 0 }
    return b.seconds
}

struct PlaybackIncident: Codable {
    var mediaID: String
    var engine: String
    var began: Date
}

// A decoder crash cannot be caught by Swift do/catch; this breadcrumb allows
// the *next* launch to avoid repeating a suspicious engine/channel combination.
@MainActor enum PlaybackCrashGuard {
    static let markerKey = "playbackIncidentV1"
    static let recoveryKey = "playbackRecoveryMediaID"
    static func inspectPreviousLaunch() {
        let defaults=UserDefaults.standard
        guard let data=defaults.data(forKey:markerKey),
              let marker=try? JSONDecoder().decode(PlaybackIncident.self,from:data) else { return }
        defaults.removeObject(forKey:markerKey)
        if Date().timeIntervalSince(marker.began) < 10*60 {
            defaults.set(marker.mediaID,forKey:recoveryKey)
        }
    }
    static func mark(_ mediaID:String, engine:String) {
        let marker=PlaybackIncident(mediaID:mediaID,engine:engine,began:Date())
        if let data=try? JSONEncoder().encode(marker) {UserDefaults.standard.set(data,forKey:markerKey)}
    }
    static func clear() {UserDefaults.standard.removeObject(forKey:markerKey)}
    static func recovered(_ item:Media) -> Bool {UserDefaults.standard.string(forKey:recoveryKey) == item.id}
    static func clearRecovery(_ item:Media) {
        if recovered(item) {UserDefaults.standard.removeObject(forKey:recoveryKey)}
    }
}
