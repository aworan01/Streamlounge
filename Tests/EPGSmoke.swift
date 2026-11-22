import Foundation
@main struct EPGSmoke {
    static func main() throws {
        let source=Source(name:"Test",address:"https://example.org/list.m3u",type:"M3U URL")
        func item(_ id:String,_ name:String,_ tvg:String="",_ group:String="UK: Sports")->Media { Media(id:id,sourceID:source.id,name:name,group:group,url:"https://example.org/stream/"+id,tvg:tvg) }
        let items=[item("a","UK: Example Sports UHD"),item("b","Example Sports FHD"),item("c","Unrelated","news.uk"),item("d","Example Sports +1"),item("e","Other", "bad"),item("f","Manual"),item("g","Duplicate")]
        let now=Date(timeIntervalSince1970:1_800_000_000);let df=DateFormatter();df.locale=Locale(identifier:"en_US_POSIX");df.timeZone=TimeZone(secondsFromGMT:0);df.dateFormat="yyyyMMddHHmmss Z";let start=df.string(from:now.addingTimeInterval(-1200));let end=df.string(from:now.addingTimeInterval(1200))
        let chans=[("sports.uk","Example Sports"),("news.uk","Example News"),("timeshift.uk","Example Sports +1"),("dup1","Duplicate"),("dup2","Duplicate"),("unwanted","Another channel")]
        let xml="<tv>"+chans.map{"<channel id=\"\($0.0)\"><display-name>\($0.1)</display-name></channel>"}.joined()+chans.map{"<programme channel=\"\($0.0)\" start=\"\(start)\" stop=\"\(end)\"><title>Test &amp; News</title><desc>Description</desc></programme>"}.joined()+"</tv>"
        let data=Data(xml.utf8);let parsed=try GuideParser(options:GuideOptions(),now:now,items:items,manual:["f":"news.uk"]).parse(data)
        precondition(parsed.programmes["unwanted"]==nil)
        let links=matchGuide(parsed,items:items,manual:["f":"news.uk"],borrow:true)
        precondition(links["a"]?.0=="sports.uk" && links["b"]?.0=="sports.uk")
        precondition(links["c"]?.1==1 && links["f"]?.1==0)
        precondition(links["d"]?.0=="timeshift.uk" && links["g"]==nil && links["e"]==nil)
        precondition(parsed.programmes["sports.uk"]?.first?.title=="Test & News")
        precondition(parsed.programmes["sports.uk"]?.first?.detail=="Description")
        let urls=guideURLs(in:"#EXTM3U x-tvg-url=\"https://example.org/one.xml.gz, guide.xml\"\n#EXTINF:-1,News",base:URL(string:source.address));precondition(urls==["https://example.org/one.xml.gz","https://example.org/guide.xml"])
        precondition(guideCountries(source,items,GuideOptions())==["UK"])
        let old=Data("{\"id\":\"\(source.id.uuidString)\",\"name\":\"Test\",\"address\":\"https://example.org/list.m3u\",\"type\":\"M3U URL\",\"user\":\"\",\"password\":\"\",\"epg\":\"\",\"pasted\":\"\"}".utf8);let migrated=try JSONDecoder().decode(Source.self,from:old);precondition(migrated.discoveredEPG==nil)
        let snapshot=GuideSnapshot(updated:now,links:["a":"0|sports.uk"],schedules:["0|sports.uk":parsed.programmes["sports.uk"]!],matched:1,total:7,feeds:1,failures:0,labels:["0|sports.uk":"Provider"])
        let roundtrip=try JSONDecoder().decode(GuideSnapshot.self,from:JSONEncoder().encode(snapshot));precondition(roundtrip.programmes(items[0]).count==1)
        if CommandLine.arguments.count>1 {let gz=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]));let inflated=try gunzipGuide(gz);precondition(String(data:inflated,encoding:.utf8)=="<tv></tv>")}
        print("PASS: XMLTV parsing, HTML entities, descriptions, exact IDs, normalized names, ambiguous matches, +1 isolation, manual mapping, relevant-channel filtering, M3U header, country detection, legacy Source migration, snapshot round trip and gzip.")
    }
}
