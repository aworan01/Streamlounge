import Foundation

@main
struct ClearKeySmoke {
    static func main() throws {
        let kid = Data((0..<16).map { UInt8($0) })
        let key = Data((16..<32).map { UInt8($0) })
        let keyHex = ClearKeyCodec.hex(key)
        let kidHex = ClearKeyCodec.hex(kid)
        precondition(ClearKeyCodec.bytes(hex: kidHex) == kid)
        precondition(ClearKeyCodec.bytes(hex: "nonsense") == nil)
        precondition(ClearKeyCodec.fromB64url(ClearKeyCodec.b64url(kid)) == kid)
        let response: [String: Any] = ["keys": [["kty":"oct", "kid":ClearKeyCodec.b64url(kid), "k":ClearKeyCodec.b64url(key)]], "type":"temporary"]
        let payload = try JSONSerialization.data(withJSONObject:response)
        let resolved = try ClearKeyCodec.key(fromJWKS:payload,wantedKID:kid)
        precondition(resolved == keyHex)
        var mismatch = false
        do { _ = try ClearKeyCodec.key(fromJWKS:payload,wantedKID:Data(repeating:0xff,count:16)) }
        catch ClearKeyFailure.noMatchingKey { mismatch = true }
        precondition(mismatch)
        let manual = ClearKeyProfile(streamURL:"https://example.org/fixture.mp4", method:"Manual key", keyID:kidHex, keyHex:keyHex)
        try ClearKeyCodec.validate(manual)
        let license = ClearKeyProfile(streamURL:"https://example.org/test.mpd", method:"License server", keyID:kidHex, licenseServer:"https://license.example.org/clearkey")
        try ClearKeyCodec.validate(license)
        print("ClearKey hex/JWKS/validation smoke tests passed")
    }
}
