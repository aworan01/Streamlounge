import Foundation

@main struct M3UProtectionSmoke {
    static func main() throws {
        let source=Source(name:"Fixture",address:"",type:"Local M3U")
        if CommandLine.arguments.count > 1 {
            let text=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
            let parsed=parseM3UDetailed(text,source:source)
            precondition(parsed.media.count == 3,"Expected 3 sample channels")
            precondition(parsed.media[0].drmType == "clearkey")
            precondition(parsed.media[0].manifestType == "dash")
            precondition(parsed.media[0].userAgent != nil)
            precondition(parsed.media[1].drmType == "widevine")
            precondition(parsed.media[2].drmType == "clearkey")
            precondition(parsed.media[2].manifestType == "hls")
            // The supplied `h` payload decodes to 17 bytes, not 16. Reject it.
            precondition(parsed.keys.isEmpty)
            precondition(parsed.warnings.count == 2)
            precondition(parsed.warnings.allSatisfy { $0.contains("17 bytes") })
            precondition(parsed.warnings.allSatisfy { !$0.contains("Zqs3RElk") })
            precondition(parseM3U(text,source:source).count == 3)
        }

        let kid=Data((0..<16).map{UInt8($0)})
        let key=Data((16..<32).map{UInt8($0)})
        func b64(_ d:Data) -> String {
            d.base64EncodedString().replacingOccurrences(of:"+",with:"-")
            .replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        }
        func entry(_ keyField:String) throws -> String {
            let obj:[String:Any] = ["keys":[["kty":"oct","kid":b64(kid),keyField:b64(key)]],"type":"temporary"]
            let json=String(data:try JSONSerialization.data(withJSONObject:obj,options:[.sortedKeys]),encoding:.utf8)!
            return "#EXTM3U\n#EXTINF:-1 group-title=\"Demo\",Test\n#KODIPROP:inputstream.adaptive.license_type=clearkey\n#KODIPROP:inputstream.adaptive.license_key=\(json)\n#EXTVLCOPT:http-user-agent=TestAgent\nhttps://example.invalid/test.mpd\n"
        }
        for field in ["k","h"] {
            let good=parseM3UDetailed(try entry(field),source:source)
            precondition(good.keys.count == 1)
            precondition(good.keys[0].keyHex.count == 32 && good.keys[0].keyIDHex.count == 32)
            precondition(good.media[0].userAgent == "TestAgent")
            let cache=String(decoding:try JSONEncoder().encode(good.media),as:UTF8.self)
            precondition(!cache.contains(good.keys[0].keyHex))
            precondition(!cache.contains(b64(key)))
        }
        print("PASS: M3U metadata, synthetic valid k/h keys, no keys in media cache" + (CommandLine.arguments.count > 1 ? ", supplied sample rejected invalid keys" : ""))
    }
}
