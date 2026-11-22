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
}
struct Media: Codable, Identifiable, Hashable {
    var id: String; var sourceID: UUID; var name: String; var group: String; var url: String
    var logo: String = ""; var tvg: String = ""; var kind: MediaKind = .live; var remoteID: String = ""
}
struct Programme: Identifiable {
    var id: String { channel + start.description + title }
    var channel: String; var start: Date; var end: Date; var title: String
}
enum StreamFailure: LocalizedError {
    case invalidURL, empty, badResponse, invalidData
    var errorDescription: String? { switch self { case .invalidURL: return "Enter a valid HTTP or HTTPS URL."; case .empty: return "No playable entries found."; case .badResponse: return "The provider rejected the request or returned an error."; case .invalidData: return "The provider returned an unexpected format." } }
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
func parseM3U(_ text: String, source: Source) -> [Media] {
    var items: [Media] = []; var meta: [String:String] = [:]; var title = ""; var group = ""; var occurrences: [String:Int] = [:]
    let base = httpURL(source.address)
    if text.contains("#EXT-X-TARGETDURATION") || text.contains("#EXT-X-STREAM-INF") {
        if let base = base { return [Media(id: source.id.uuidString+base.absoluteString,sourceID:source.id,name:source.name,group:"Ungrouped",url:base.absoluteString)] }; return []
    }
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of:"\u{FEFF}",with:"")
        if line.hasPrefix("#EXTINF:") {
            meta = attributes(line); title = ""; group = meta["group-title"] ?? ""
            var quoted: Character? = nil
            for idx in line.indices {
                let c = line[idx]
                if c == "\"" { quoted = quoted == nil ? c : nil }
                if c == "," && quoted == nil { title = String(line[line.index(after:idx)...]).trimmingCharacters(in:.whitespaces); break }
            }
        } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)).trimmingCharacters(in:.whitespaces) }
        else if !line.hasPrefix("#") && !line.isEmpty {
            if let url = httpURL(line) ?? (base.flatMap { URL(string:line,relativeTo:$0)?.absoluteURL }.flatMap { httpURL($0.absoluteString) }) {
                let key = url.absoluteString; occurrences[key, default:0] += 1
                items.append(Media(id:source.id.uuidString+"|"+key+"|"+String(occurrences[key]!),sourceID:source.id,name:title.isEmpty ? (meta["tvg-name"] ?? url.lastPathComponent) : title,group:group.isEmpty ? "Ungrouped" : group,url:key,logo:meta["tvg-logo"] ?? "",tvg:meta["tvg-id"] ?? "",kind:mediaKind(url,radio:meta["radio"] == "true")))
            }; meta = [:]; title = ""; group = ""
        }
    }; return items
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
final class XMLGuide: NSObject, XMLParserDelegate {
    var results:[Programme]=[]; private var channel=""; private var start:Date?; private var end:Date?; private var title=""; private var inTitle=false; private var inProgramme=false
    private let date:DateFormatter = { let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.dateFormat="yyyyMMddHHmmss Z"; f.timeZone=TimeZone(secondsFromGMT:0); return f }()
    func parse(_ data:Data) throws -> [Programme] { let p=XMLParser(data:data); p.delegate=self; p.shouldResolveExternalEntities=false; guard p.parse() else { throw StreamFailure.invalidData }; return results }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        if name == "programme" { channel=a["channel"] ?? ""; start=parseDate(a["start"]); end=parseDate(a["stop"]); title=""; inProgramme=true }
        if name == "title" && inProgramme && title.isEmpty { inTitle=true }
    }
    func parseDate(_ s:String?) -> Date? { guard let s=s else { return nil }; return date.date(from:s.count == 14 ? s+" +0000" : s) }
    func parser(_ parser:XMLParser,foundCharacters string:String) { if inTitle { title += string } }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        if name == "title" { inTitle=false }; if name == "programme" { if let start=start,let end=end,end>Date().addingTimeInterval(-86400),start<Date().addingTimeInterval(7*86400) { results.append(Programme(channel:channel,start:start,end:end,title:title)) }; inProgramme=false }
    }
}
