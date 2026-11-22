import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

enum MediaKind: String, Codable, CaseIterable { case live = "Live TV", movie = "Movies", series = "Series", episode = "Episode" }
struct Source: Codable, Identifiable, Equatable {
    var id = UUID(); var name: String; var address: String; var type: String
    var user = ""; var password = ""; var epg = ""; var pasted = ""
    var discoveredEPG: [String]? = nil
    var epgCountries: String? = nil
}
struct Media: Codable, Identifiable, Hashable {
    var id: String; var sourceID: UUID; var name: String; var group: String; var url: String
    var logo: String = ""; var tvg: String = ""; var kind: MediaKind = .live; var remoteID: String = ""
    // Optional for backwards-compatible decoding of existing channel caches.
    var userAgent: String? = nil; var referer: String? = nil; var manifestType: String? = nil; var drmType: String? = nil
}
struct Programme: Identifiable, Codable {
    var id: String { channel + start.description + title }
    var channel: String; var start: Date; var end: Date; var title: String; var detail: String = ""
}
/// Human-readable picture class from the decoder-reported raster size.
/// Streaming bitrate / the text "4K" in a channel name cannot establish quality.
func qualityTier(width:Double,height:Double)->String {
    guard width.isFinite,height.isFinite,width>0,height>0 else {return "—"}
    let longer=max(width,height),shorter=min(width,height)
    if longer>=3800 || shorter>=2100 {return "4K"}
    if longer>=1900 || shorter>=1000 {return "FHD"}
    if longer>=1250 || shorter>=700 {return "HD"}
    return "SD"
}
enum StreamFailure: LocalizedError {
    case invalidURL, empty, badResponse, invalidData, htmlInsteadOfPlaylist
    var errorDescription: String? { switch self { case .invalidURL: return "Enter a valid HTTP or HTTPS URL."; case .empty: return "No playable entries found."; case .badResponse: return "The provider rejected the request or returned an error."; case .invalidData: return "The provider returned an unexpected format."; case .htmlInsteadOfPlaylist: return "The server returned a web/login/Cloudflare page rather than an M3U playlist. A provider-authorized M3U feed or supported API is required for native Apple TV playback." } }
}
func httpURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(), ["http","https"].contains(scheme), url.host != nil else { return nil }; return url
}
func fetch(_ url: URL) async throws -> Data {
    var req = URLRequest(url: url); req.timeoutInterval = 60
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let res = response as? HTTPURLResponse, (200..<300).contains(res.statusCode) else { throw StreamFailure.badResponse }; return data
}
// Swift adaptation of IPTVnator v0.25.0 m3u-vod-detection.util.ts (MIT).
func mediaKind(_ url: URL, radio: Bool = false) -> MediaKind {
    if radio { return .live }
    let parts = url.pathComponents.map { $0.lowercased() }
    if parts.contains("series") { return .episode }
    let containers: Set<String> = ["avi","asf","divx","flv","m2ts","m4v","mkv","mov","mp4","mpeg","mpg","rm","rmvb","vob","webm","wmv"]
    return containers.contains(url.pathExtension.lowercased()) || parts.contains(where: { ["movie","movies","vod"].contains($0) }) ? .movie : .live
}
func attributes(_ line: String) -> [String:String] {
    let regex = try! NSRegularExpression(pattern: #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s,]+))"#)
    let ns = line as NSString; var out: [String:String] = [:]
    for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
        for i in 2...4 where match.range(at:i).location != NSNotFound { out[ns.substring(with:match.range(at:1)).lowercased()] = ns.substring(with:match.range(at:i)); break }
    }; return out
}
// DRM secrets are NEVER included in Media or the serialized media cache.
// They are transferred to ClearKeyVault (tvOS Keychain) by Library.load.
struct PlaylistClearKey {
    let streamURL: String
    let keyIDHex: String
    let keyHex: String
}
struct ParsedM3U {
    var media: [Media] = []
    var keys: [PlaylistClearKey] = []
    var warnings: [String] = []
}
private func playlistB64Bytes(_ input: String) -> Data? {
    let normalized = input.replacingOccurrences(of:"-",with:"+")
                          .replacingOccurrences(of:"_",with:"/")
    return Data(base64Encoded: normalized + String(repeating:"=",count:(4-normalized.count%4)%4))
}
private func playlistHex(_ bytes: Data) -> String {
    bytes.map {String(format:"%02x",$0)}.joined()
}
private func playlistKeyBytes(_ raw: String) -> Data? {
    let value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
    if value.count == 32, value.unicodeScalars.allSatisfy({(48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)}) {
        var bytes=Data()
        var i=value.startIndex
        while i<value.endIndex {
            let end=value.index(i,offsetBy:2)
            guard let byte=UInt8(value[i..<end],radix:16) else{return nil}
            bytes.append(byte);i=end
        }
        return bytes.count == 16 ? bytes : nil
    }
    guard let decoded=playlistB64Bytes(value),decoded.count == 16 else {return nil}
    return decoded
}
private func clearKeyDiagnostic(_ raw: String) -> String {
    guard let data=raw.data(using:.utf8),
          let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
          let first=(json["keys"] as? [[String:Any]])?.first else {
        return "This entry has no parseable ClearKey JSON object."
    }
    let kidText=first["kid"] as? String ?? ""
    let value=(first["k"] as? String) ?? (first["h"] as? String) ?? ""
    func length(_ value:String)->Int? {
        let compact=value.trimmingCharacters(in:.whitespacesAndNewlines)
        if compact.count == 32, compact.allSatisfy({$0.isHexDigit}) {return 16}
        return playlistB64Bytes(compact)?.count
    }
    let kidCount=length(kidText).map {"\($0)"} ?? "invalid"
    let keyCount=length(value).map {"\($0)"} ?? "invalid"
    return "ClearKey KID is \(kidCount) bytes and content key is \(keyCount) bytes; both must be exactly 16 bytes. Obtain the correct values from the authorized provider."
}
private func clearKeyFromPlaylist(_ raw: String) -> (kid:String,key:String)? {
    // Kodi/inputstream-adaptive M3U: supports JWKS `k` and provider `h` forms.
    // `h` is NOT a W3C JWK property: accept only when it contains a valid
    // 16-byte base64url/hex key. No key discovery or DRM-system conversion.
    guard let payload=raw.data(using:.utf8),
          let dict=(try? JSONSerialization.jsonObject(with:payload)) as? [String:Any],
          let entries=dict["keys"] as? [[String:Any]] else{return nil}
    for entry in entries where entry["kty"] as? String == "oct" {
        guard let kidText=entry["kid"] as? String,
              let keyText=(entry["k"] as? String) ?? (entry["h"] as? String),
              let kid=playlistKeyBytes(kidText),let key=playlistKeyBytes(keyText) else {continue}
        return (playlistHex(kid),playlistHex(key))
    }
    return nil
}
func parseM3UDetailed(_ text: String, source: Source) -> ParsedM3U {
    var result=ParsedM3U()
    var meta:[String:String]=[:]
    var title="",group=""
    var kodi:[String:String]=[:],vlc:[String:String]=[:]
    var occurrences:[String:Int]=[:]
    let base=httpURL(source.address)
    if text.contains("#EXT-X-TARGETDURATION") || text.contains("#EXT-X-STREAM-INF") {
        if let base=base {result.media=[Media(id:source.id.uuidString+base.absoluteString,sourceID:source.id,name:source.name,group:"Ungrouped",url:base.absoluteString)]}
        return result
    }
    for raw in text.components(separatedBy:.newlines) {
        let line=raw.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\u{FEFF}",with:"")
        if line.hasPrefix("#EXTINF:") {
            meta=attributes(line);title="";group=meta["group-title"] ?? "";kodi=[:];vlc=[:]
            var quoted=false
            for index in line.indices {
                if line[index] == "\"" {quoted.toggle()}
                if line[index] == "," && !quoted {title=String(line[line.index(after:index)...]).trimmingCharacters(in:.whitespaces);break}
            }
        } else if line.hasPrefix("#EXTGRP:") {
            group=String(line.dropFirst(8)).trimmingCharacters(in:.whitespaces)
        } else if line.hasPrefix("#KODIPROP:") {
            let body=String(line.dropFirst("#KODIPROP:".count))
            if let sep=body.firstIndex(of:"=") {
                kodi[String(body[..<sep]).trimmingCharacters(in:.whitespaces).lowercased()]=String(body[body.index(after:sep)...]).trimmingCharacters(in:.whitespaces)
            }
        } else if line.hasPrefix("#EXTVLCOPT:") {
            let body=String(line.dropFirst("#EXTVLCOPT:".count))
            if let sep=body.firstIndex(of:"=") {
                vlc[String(body[..<sep]).trimmingCharacters(in:.whitespaces).lowercased()]=String(body[body.index(after:sep)...]).trimmingCharacters(in:.whitespaces)
            }
        } else if !line.hasPrefix("#") && !line.isEmpty {
            if let url=httpURL(line) ?? (base.flatMap{URL(string:line,relativeTo:$0)?.absoluteURL}.flatMap{httpURL($0.absoluteString)}) {
                let key=url.absoluteString;occurrences[key,default:0]+=1
                let license=kodi["inputstream.adaptive.license_type"]?.lowercased() ?? ""
                var media=Media(id:source.id.uuidString+"|"+key+"|"+String(occurrences[key]!),sourceID:source.id,
                    name:title.isEmpty ? (meta["tvg-name"] ?? url.lastPathComponent) : title,
                    group:group.isEmpty ? "Ungrouped" : group,url:key,logo:meta["tvg-logo"] ?? "",
                    tvg:meta["tvg-id"] ?? "",kind:mediaKind(url,radio:meta["radio"] == "true"))
                media.userAgent=vlc["http-user-agent"]
                media.referer=vlc["http-referrer"] ?? vlc["http-referer"]
                media.manifestType=kodi["inputstream.adaptive.manifest_type"]
                if license.contains("widevine") {media.drmType="widevine"}
                else if license.contains("clearkey") {
                    media.drmType="clearkey"
                    if let rawKey=kodi["inputstream.adaptive.license_key"],
                       let pair=clearKeyFromPlaylist(rawKey) {
                        result.keys.append(PlaylistClearKey(streamURL:key,keyIDHex:pair.kid,keyHex:pair.key))
                    } else {
                        let reason=clearKeyDiagnostic(kodi["inputstream.adaptive.license_key"] ?? "")
                        result.warnings.append("ClearKey entry \(media.name): \(reason)")
                    }
                }
                result.media.append(media)
            }
            meta=[:];title="";group="";kodi=[:];vlc=[:]
        }
    }
    return result
}
func parseM3U(_ text: String, source: Source) -> [Media] {
    parseM3UDetailed(text,source:source).media
}

struct Xtream {
    let source: Source
    func base() throws -> URL { guard let u = httpURL(source.address), var c = URLComponents(url:u,resolvingAgainstBaseURL:false) else { throw StreamFailure.invalidURL }; c.query=nil; c.fragment=nil; if c.path.hasSuffix("/player_api.php") { c.path = String(c.path.dropLast(15)) }; while c.path.hasSuffix("/") { c.path.removeLast() }; guard let url=c.url else { throw StreamFailure.invalidURL }; return url }
    func api(_ action: String, extra: [URLQueryItem] = []) async throws -> Any {
        let u = try base().appendingPathComponent("player_api.php")
        var c = URLComponents(url:u,resolvingAgainstBaseURL:false)!
        c.queryItems = [URLQueryItem(name:"username",value:source.user),URLQueryItem(name:"password",value:source.password),URLQueryItem(name:"action",value:action)] + extra
        guard let endpoint=c.url else { throw StreamFailure.invalidURL }; return try JSONSerialization.jsonObject(with:await fetch(endpoint))
    }
    // Swift adaptation of IPTVnator XtreamUrlService live/VOD/episode URL constructors (MIT).
    func stream(_ path: String, _ id: String, _ ext: String) throws -> String {
        var c = URLComponents(url:try base(),resolvingAgainstBaseURL:false)!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        let segments = [path,source.user,source.password,id+"."+ext].map { $0.addingPercentEncoding(withAllowedCharacters:allowed) ?? "" }
        c.percentEncodedPath += "/"+segments.joined(separator:"/")
        guard let u=c.url else { throw StreamFailure.invalidURL }; return u.absoluteString
    }
    func catalog(_ kind: MediaKind) async throws -> [Media] {
        let prefix = kind == .live ? "live" : (kind == .movie ? "vod" : "series")
        let action = kind == .series ? "get_series" : "get_\(prefix)_streams"
        let cats = (try? await api("get_\(prefix)_categories")) as? [[String:Any]] ?? []
        var groups:[String:String]=[:]; for c in cats { groups[str(c["category_id"])]=str(c["category_name"]) }
        guard let rows = try await api(action) as? [[String:Any]] else { throw StreamFailure.invalidData }
        return try rows.compactMap { r in
            let id = str(r[kind == .series ? "series_id" : "stream_id"]); guard !id.isEmpty else { return nil }
            let ext = str(r["container_extension"]); let direct = str(r["direct_source"])
            let url: String
            if kind == .series { url = "" } else if kind == .movie, let directURL=httpURL(direct) { url=directURL.absoluteString } else { url=try stream(kind == .live ? "live" : "movie",id,kind == .live ? "m3u8" : (ext.isEmpty ? "mp4" : ext)) }
            return Media(id:source.id.uuidString+"|"+kind.rawValue+"|"+id,sourceID:source.id,name:str(r["name"]),group:groups[str(r["category_id"])] ?? "Ungrouped",url:url,logo:str(r[kind == .series ? "cover" : "stream_icon"]),tvg:str(r["epg_channel_id"]),kind:kind,remoteID:id)
        }
    }
    func episodes(_ series: Media) async throws -> [Media] {
        guard let obj=try await api("get_series_info",extra:[URLQueryItem(name:"series_id",value:series.remoteID)]) as? [String:Any], let seasons=obj["episodes"] as? [String:[[String:Any]]] else { throw StreamFailure.invalidData }
        return try seasons.keys.sorted { ($0 as NSString).integerValue < ($1 as NSString).integerValue }.flatMap { season in
            try (seasons[season] ?? []).compactMap { r in
                let id=str(r["id"]); guard !id.isEmpty else { return nil }; let ext=str(r["container_extension"])
                return Media(id:source.id.uuidString+"|episode|"+id,sourceID:source.id,name:str(r["episode_num"])+" · "+str(r["title"]),group:"Season "+season,url:try stream("series",id,ext.isEmpty ? "mp4" : ext),logo:series.logo,kind:.episode,remoteID:id)
            }
        }
    }
}
func str(_ value: Any?) -> String { if let s=value as? String { return s }; if let n=value as? NSNumber { return n.stringValue }; return "" }

func formatPlaybackTime(_ seconds:Int)->String {
    let h=seconds/3600,m=(seconds/60)%60,s=seconds%60
    return h>0 ? String(format:"%d:%02d:%02d",h,m,s) : String(format:"%d:%02d",m,s)
}
