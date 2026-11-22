import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

// Independent Swift implementation. Architecture reference: IMD TV (GPL-3.0),
// https://github.com/majorleeevil/imd-tv. No Kotlin source is included.
struct GuideOptions: Sendable {
    var external = true; var provider = true; var custom = true
    var order = "Provider first"; var countries = ""; var days = 7; var past = 1
    var offset = 0; var borrow = true
    static func read(_ d: UserDefaults = .standard) -> Self {
        var o = Self()
        o.external = d.object(forKey:"epgExternal") as? Bool ?? true
        o.provider = d.object(forKey:"epgProvider") as? Bool ?? true
        o.custom = d.object(forKey:"epgCustom") as? Bool ?? true
        o.order = d.string(forKey:"epgOrder") ?? "Provider first"
        o.countries = d.string(forKey:"epgCountries") ?? ""
        o.days = max(1,min(14,d.object(forKey:"epgDays") as? Int ?? 7))
        o.past = max(0,min(7,d.object(forKey:"epgPast") as? Int ?? 1))
        o.offset = max(-720,min(720,d.integer(forKey:"epgOffset")))
        o.borrow = d.object(forKey:"epgBorrow") as? Bool ?? true
        return o
    }
}
struct GuideSnapshot: Codable {
    var updated: Date; var links: [String:String]; var schedules: [String:[Programme]]
    var matched: Int; var total: Int; var feeds: Int; var failures: Int
    var labels: [String:String]; var status: [String] = []
    // No URLs (which may contain credentials) in diagnostics.
    func programmes(_ item: Media) -> [Programme] { links[item.id].flatMap{ schedules[$0] } ?? [] }
}
struct GuideFeed { var url: URL; var label: String }
struct GuideChannel { var id: String; var names:[String] }
struct ParsedGuide { var channels:[GuideChannel]; var programmes:[String:[Programme]] }
private let epgBase = URL(string:"https://epgshare01.online/epgshare01/")!
private let maxXML = 160 * 1024 * 1024
private let maxWire = 64 * 1024 * 1024

func guideURLs(in text: String, base: URL?) -> [String] {
    guard let line = text.components(separatedBy:.newlines).first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("#EXTM3U")}) else{return []}
    let a=attributes(line)
    return [a["url-tvg"],a["x-tvg-url"],a["tvg-url"]].compactMap{$0}.flatMap{$0.components(separatedBy:CharacterSet(charactersIn:",").union(.whitespacesAndNewlines))}.compactMap{v in
        let value=v.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else{return nil}
        return (httpURL(value) ?? base.flatMap{URL(string:value,relativeTo:$0)?.absoluteURL}.flatMap{httpURL($0.absoluteString)})?.absoluteString
    }
}
func providerGuideURLs(_ source:Source) -> [URL] {
    var values=(source.discoveredEPG ?? []).compactMap(httpURL)
    if source.type == "Xtream",let base=try? Xtream(source:source).base(),var c=URLComponents(url:base.appendingPathComponent("xmltv.php"),resolvingAgainstBaseURL:false) {
        c.queryItems=[URLQueryItem(name:"username",value:source.user),URLQueryItem(name:"password",value:source.password)]
        if let url=c.url {values.append(url)}
    }
    return values
}
func guideCountry(_ value:String) -> String? {
    let s=value.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
    let names:[String:String]=["UNITED KINGDOM":"UK","GREAT BRITAIN":"UK","USA":"US","UNITED STATES":"US","NIGERIA":"NG","SOUTH AFRICA":"ZA","CANADA":"CA","AUSTRALIA":"AU","FRANCE":"FR","GERMANY":"DE","SPAIN":"ES","ITALY":"IT","INDIA":"IN","GHANA":"GH","KENYA":"KE","PORTUGAL":"PT","NETHERLANDS":"NL","IRELAND":"IE","UAE":"AE","SAUDI ARABIA":"SA"]
    for key in names.keys.sorted(by:{$0.count>$1.count}) where s == key || s.hasPrefix(key+" ") || s.hasPrefix(key+"|") || s.hasPrefix(key+":") || s.hasPrefix(key+"-") {return names[key]}
    let pattern = #"^(?:[|\[(]\s*)?([A-Z]{2})(?=\s*(?:[|\]):\-]|$)|\s)"#
    if let r=try? NSRegularExpression(pattern:pattern),let m=r.firstMatch(in:s,range:NSRange(s.startIndex...,in:s)),let range=Range(m.range(at:1),in:s) {
        let code=String(s[range]);return code == "GB" ? "UK" : code
    };return nil
}
func guideCountries(_ source:Source,_ items:[Media],_ settings:GuideOptions) -> [String] {
    let override=(source.epgCountries ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
    let selection=override.isEmpty ? settings.countries : override
    if !selection.isEmpty {return Array(Set(selection.components(separatedBy:CharacterSet(charactersIn:",; ")).compactMap(guideCountry))).sorted()}
    var counts:[String:Int]=[:]
    for item in items {if let c=guideCountry(item.group) ?? guideCountry(item.name){counts[c,default:0]+=1}}
    return counts.keys.sorted{(counts[$0] ?? 0) == (counts[$1] ?? 0) ? $0<$1 : (counts[$0] ?? 0)>(counts[$1] ?? 0)}
}
func guideName(_ text:String, stripQuality:Bool) -> String {
    var s=text.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")).lowercased()
    if stripQuality {
        s=s.replacingOccurrences(of:#"^\s*(?:\|[a-z]{2,3}\||\[[a-z]{2,3}\]|[a-z]{2,3}\s*[:|]|[a-z]{2,3}\s+-)\s*"#,with:"",options:.regularExpression)
        s=s.replacingOccurrences(of:#"\bvip\b"#,with:" ",options:.regularExpression)
        // Preserve regional, time-shift and numbered channel distinctions.
        s=s.replacingOccurrences(of:#"(?:[\s|\-]*(?:\((?:4k|uhd|fhd|hd|sd)\)|\[(?:4k|uhd|fhd|hd|sd)\]|\b(?:4k|uhd|fhd|hd|sd)\b))+\s*$"#,with:"",options:.regularExpression)
    }
    return s.replacingOccurrences(of:#"[^\p{L}\p{N}+]+"#,with:" ",options:.regularExpression).trimmingCharacters(in:.whitespacesAndNewlines)
}
func gunzipGuide(_ data: Data) throws -> Data {
    guard data.starts(with:[0x1f,0x8b]) else {guard data.count<=maxXML else{throw StreamFailure.invalidData};return data}
    var stream=z_stream()
    guard inflateInit2_(&stream, MAX_WBITS+16,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else{throw StreamFailure.invalidData}
    defer{inflateEnd(&stream)}
    var output=Data();let chunkSize=64*1024;var chunk=[UInt8](repeating:0,count:chunkSize)
    try data.withUnsafeBytes{raw in
        guard let ptr=raw.bindMemory(to:UInt8.self).baseAddress else{throw StreamFailure.invalidData}
        stream.next_in=UnsafeMutablePointer(mutating:ptr);stream.avail_in=UInt32(data.count)
        while true {
            let status=chunk.withUnsafeMutableBytes{buf -> Int32 in
                stream.next_out=buf.bindMemory(to:UInt8.self).baseAddress;stream.avail_out=UInt32(chunkSize)
                return inflate(&stream,Z_NO_FLUSH)
            }
            let n=chunkSize-Int(stream.avail_out)
            guard output.count+n<=maxXML else{throw StreamFailure.invalidData}
            output.append(contentsOf:chunk.prefix(n))
            if status == Z_STREAM_END {break}
            guard status == Z_OK,n>0 || stream.avail_in>0 else{throw StreamFailure.invalidData}
        }
    };return output
}
func downloadGuide(_ url: URL) async throws -> Data {
    var req=URLRequest(url:url);req.timeoutInterval=60
    let (file,response)=try await URLSession.shared.download(for:req)
    defer{try? FileManager.default.removeItem(at:file)}
    guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else{throw StreamFailure.badResponse}
    let size=(try FileManager.default.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0
    // A server may transparently decompress Content-Encoding: gzip.
    guard size>0,size<=maxWire else{throw StreamFailure.invalidData}
    return try gunzipGuide(Data(contentsOf:file,options:.mappedIfSafe))
}
final class GuideParser:NSObject,XMLParserDelegate {
    private let lower:Date;private let upper:Date;private let offset:TimeInterval
    private let requestedIDs:Set<String>?;private let requestedNames:Set<String>;private var wantedIDs:Set<String>?;private var keepProgramme=true
    private var channels:[GuideChannel]=[];private var programmes:[String:[Programme]]=[:];private var count=0
    private var channelID="";private var names:[String]=[];private var inChannel=false;private var inProgramme=false;private var capture="";private var value="";private var title="";private var detail="";private var start:Date?;private var stop:Date?;private var root=false;private var exceeded=false
    private let date:DateFormatter={let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat="yyyyMMddHHmmss Z";return f}()
    init(options:GuideOptions,now:Date=Date(),items:[Media]?=nil,manual:[String:String]=[:]){
        lower=now.addingTimeInterval(-Double(options.past)*86400);upper=now.addingTimeInterval(Double(options.days)*86400);offset=Double(options.offset)*60
        requestedIDs=items.map{Set($0.flatMap{[$0.tvg.lowercased(),manual[$0.id]?.lowercased() ?? ""]}.filter{!$0.isEmpty})}
        requestedNames=Set((items ?? []).flatMap{[guideName($0.name,stripQuality:false),guideName($0.name,stripQuality:true)]}.filter{!$0.isEmpty})
    }
    func parse(_ data:Data)throws->ParsedGuide{let p=XMLParser(data:data);p.delegate=self;p.shouldResolveExternalEntities=false;guard p.parse(),root,!exceeded else{throw StreamFailure.invalidData};return ParsedGuide(channels:channels,programmes:programmes)}
    private func parseDate(_ input:String?)->Date? {guard let s=input?.trimmingCharacters(in:.whitespacesAndNewlines) else{return nil};return date.date(from:s.count == 14 ? s+" +0000":s)?.addingTimeInterval(offset)}
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes a:[String:String]) {
        switch elementName {
        case "tv":root=true
        case "channel":inChannel=true;channelID=a["id"] ?? "";names=[]
        case "programme":
            inProgramme=true;channelID=a["channel"] ?? "";title="";detail=""
            if wantedIDs==nil,let ids=requestedIDs,!channels.isEmpty {
                var found=ids
                for c in channels where c.names.contains(where:{requestedNames.contains(guideName($0,stripQuality:false)) || requestedNames.contains(guideName($0,stripQuality:true))}) {found.insert(c.id.lowercased())}
                wantedIDs=found
            }
            keepProgramme=wantedIDs?.contains(channelID.lowercased()) ?? true
            start=keepProgramme ? parseDate(a["start"]) : nil;stop=keepProgramme ? parseDate(a["stop"]) : nil
        case "display-name" where inChannel,"title" where inProgramme && keepProgramme,"desc" where inProgramme && keepProgramme:capture=elementName;value=""
        default:break
        }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String){if !capture.isEmpty,value.utf8.count<2500 {value+=String(string.prefix(2500))}}
    func parser(_ parser:XMLParser,didEndElement e:String,namespaceURI:String?,qualifiedName:String?) {
        if e==capture {let text=value.trimmingCharacters(in:.whitespacesAndNewlines);if e=="display-name",!text.isEmpty {names.append(text)};if e=="title",title.isEmpty{title=text};if e=="desc",detail.isEmpty{detail=String(text.prefix(650))};capture=""}
        if e=="channel" {if !channelID.isEmpty{channels.append(GuideChannel(id:channelID,names:names))};inChannel=false;if channels.count>100000{exceeded=true;parser.abortParsing()}}
        if e=="programme" {inProgramme=false;guard let s=start,let t=stop,s<t,t>lower,s<upper,!channelID.isEmpty,!title.isEmpty else{return};count+=1;if count>300000{exceeded=true;parser.abortParsing();return};programmes[channelID,default:[]].append(Programme(channel:channelID,start:s,end:t,title:title,detail:detail))}
    }
}
struct GuideCandidate { var key:String; var rank:Int; var priority:Int; var fresh:Bool }
func matchGuide(_ feed:ParsedGuide,items:[Media],manual:[String:String],borrow:Bool)->[String:(String,Int)] {
    var ids:[String:String]=[:];var exact:[String:Set<String>]=[:];var clean:[String:Set<String>]=[:]
    let valid=Set(feed.programmes.keys)
    for id in valid{ids[id.lowercased()]=id}
    for c in feed.channels where valid.contains(c.id) { for n in c.names {let a=guideName(n,stripQuality:false);let b=guideName(n,stripQuality:true);if !a.isEmpty {exact[a,default:[]].insert(c.id)};if !b.isEmpty{clean[b,default:[]].insert(c.id)}} }
    var out:[String:(String,Int)]=[:]
    for item in items {
        if let override=manual[item.id],!override.isEmpty {if let id=ids[override.lowercased()]{out[item.id]=(id,0)};continue}
        if !item.tvg.isEmpty,let id=ids[item.tvg.lowercased()]{out[item.id]=(id,1);continue}
        let a=guideName(item.name,stripQuality:false);if let hits=exact[a],hits.count==1,let id=hits.first{out[item.id]=(id,2);continue}
        let b=guideName(item.name,stripQuality:true);if let hits=clean[b],hits.count==1,let id=hits.first{out[item.id]=(id,3)}
    }
    if borrow {
        var siblings:[String:Set<String>]=[:]
        for item in items {if let hit=out[item.id],hit.1<=2 {let key=(guideCountry(item.group) ?? guideCountry(item.name) ?? item.group.lowercased())+"|"+guideName(item.name,stripQuality:true);siblings[key,default:[]].insert(hit.0)}}
        for item in items where out[item.id]==nil && manual[item.id]==nil {let key=(guideCountry(item.group) ?? guideCountry(item.name) ?? item.group.lowercased())+"|"+guideName(item.name,stripQuality:true);if let hits=siblings[key],hits.count==1,let id=hits.first {out[item.id]=(id,4)}}
    };return out
}
func discoverGuideFeeds(countries:[String]) async throws -> [GuideFeed] {
    guard !countries.isEmpty else{return []}
    let data=try await downloadGuide(epgBase);guard let html=String(data:data,encoding:.utf8) else{throw StreamFailure.invalidData}
    let regex=try NSRegularExpression(pattern:#"href\s*=\s*["'](epg_ripper_([A-Z]{2})\d*\.xml\.gz)["']"#,options:[.caseInsensitive]);let ns=html as NSString;let want=Set(countries);var seen=Set<String>();var list:[GuideFeed]=[]
    for m in regex.matches(in:html,range:NSRange(location:0,length:ns.length)) {let name=ns.substring(with:m.range(at:1));let code=ns.substring(with:m.range(at:2)).uppercased();if want.contains(code),seen.insert(name).inserted{list.append(GuideFeed(url:epgBase.appendingPathComponent(name),label:"EPGShare "+name.replacingOccurrences(of:"epg_ripper_",with:"").replacingOccurrences(of:".xml.gz",with:"")))}}
    return list.sorted{(countries.firstIndex(of:String($0.label.dropFirst(9).prefix(2))) ?? 999)<(countries.firstIndex(of:String($1.label.dropFirst(9).prefix(2))) ?? 999)}
}
func refreshGuide(source:Source,items:[Media],options:GuideOptions,manual:[String:String]) async -> GuideSnapshot {
    let countries=guideCountries(source,items,options);var failures=0;var notes:[String]=[]
    let provider:[GuideFeed]=options.provider ? providerGuideURLs(source).enumerated().map{GuideFeed(url:$0.element,label:"Provider \($0.offset+1)")} : []
    let custom:[GuideFeed]=options.custom ? source.epg.components(separatedBy:.whitespacesAndNewlines).compactMap(httpURL).enumerated().map{GuideFeed(url:$0.element,label:"Custom \($0.offset+1)")} : []
    var external:[GuideFeed]=[]
    if options.external {if countries.isEmpty{notes.append("No country detected. Set country codes in EPG settings or playlist editor.")}else{do{external=try await discoverGuideFeeds(countries:countries);if external.isEmpty{notes.append("No EPGShare feeds for selected countries.")}}catch{failures+=1;notes.append("EPGShare index unavailable.")}}}
    let ordered:[GuideFeed]
    switch options.order {case "Custom first":ordered=custom+provider+external;case "External first":ordered=external+provider+custom;default:ordered=provider+custom+external}
    var seen=Set<URL>();let unique=ordered.filter{seen.insert($0.url).inserted};let feeds=Array(unique.prefix(20));if unique.count>feeds.count{notes.append("20-feed safety limit; narrow the country selection.")}
    var chosen:[String:GuideCandidate]=[:];var schedules:[String:[Programme]]=[:];var labels:[String:String]=[:];var success=0;let now=Date()
    for (i,f) in feeds.enumerated() {
        do {
            let data=try await downloadGuide(f.url)
            let eligible=items.filter { item in
                guard f.label.hasPrefix("EPGShare "),let country=guideCountry(item.group) ?? guideCountry(item.name) else{return true}
                return country == String(f.label.dropFirst(9).prefix(2)) || manual[item.id] != nil
            }
            let parsed=try GuideParser(options:options,now:now,items:eligible,manual:manual).parse(data)
            let matches=matchGuide(parsed,items:eligible,manual:manual,borrow:options.borrow)
            var keys:[String:String]=[:];var freshByID:[String:Bool]=[:]
            for (media,hit) in matches {
                guard let ps=parsed.programmes[hit.0],!ps.isEmpty else{continue}
                let fresh:Bool;if let value=freshByID[hit.0]{fresh=value}else{fresh=ps.contains{$0.start<=now && $0.end>now};freshByID[hit.0]=fresh}
                if let old=chosen[media] {
                    // Manual override first; current schedule before stale, then exactness and source order.
                    if old.rank==0 && hit.1 != 0 {continue}
                    if hit.1 != 0 && old.fresh != fresh {if old.fresh{continue}}
                    else if old.rank < hit.1 {continue}
                    else if old.rank == hit.1 && old.priority <= i {continue}
                }
                let key="\(i)|"+hit.0
                if keys[hit.0]==nil {keys[hit.0]=key;schedules[key]=Array(ps.sorted{$0.start<$1.start}.prefix(400));labels[key]=f.label}
                chosen[media]=GuideCandidate(key:key,rank:hit.1,priority:i,fresh:fresh)
            };let activeKeys=Set(chosen.values.map(\.key));schedules=schedules.filter{activeKeys.contains($0.key)};labels=labels.filter{activeKeys.contains($0.key)};success+=1;notes.append("\(f.label): \(matches.count) matches")
        }catch{failures+=1;notes.append("\(f.label): unavailable or over size limit")}
    }
    let used=Set(chosen.values.map(\.key));schedules=schedules.filter{used.contains($0.key)};labels=labels.filter{used.contains($0.key)}
    return GuideSnapshot(updated:Date(),links:chosen.mapValues(\.key),schedules:schedules,matched:chosen.count,total:items.count,feeds:success,failures:failures,labels:labels,status:notes)
}
