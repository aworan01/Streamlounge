import Foundation
import SwiftUI
import Combine
import Security
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ClearKey/CENC settings for content whose playback keys or license-service
// access were supplied to the user by an authorized provider. No automated
// key discovery, key extraction, or other DRM systems are implemented.
struct ClearKeyProfile: Codable, Identifiable {
    var streamURL: String
    var method: String = "Manual key"
    var keyID: String = ""           // 16-byte KID, hexadecimal
    var keyHex: String = ""         // 16-byte AES key, hexadecimal
    var licenseServer: String = ""  // HTTPS W3C ClearKey JSON endpoint
    var enabled: Bool = true
    var id: String { streamURL }
}

enum ClearKeyFailure: LocalizedError {
    case invalidStreamURL, invalidKeyID, invalidKey, invalidLicenseURL
    case noProfile, invalidServerResponse, noMatchingKey, httpError(Int), storageFailure(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidStreamURL: return "Enter a valid HTTP or HTTPS stream URL."
        case .invalidKeyID: return "Enter a 32-character hexadecimal Key ID (KID)."
        case .invalidKey: return "The ClearKey value must be 32 hexadecimal characters (16 bytes)."
        case .invalidLicenseURL: return "Enter an HTTPS ClearKey license-server URL."
        case .noProfile: return "No enabled ClearKey configuration exists for this stream."
        case .invalidServerResponse: return "The license server returned an unsupported or invalid ClearKey response."
        case .noMatchingKey: return "The license server did not return a key matching the specified KID."
        case let .httpError(code): return "The license server returned HTTP \(code)."
        case let .storageFailure(code): return "Secure storage failed (\(code)). Check the Apple TV signing configuration."
        }
    }
}

// Pure helpers are also tested on Linux, separate from the tvOS Keychain UI.
enum ClearKeyCodec {
    static func bytes(hex input: String) -> Data? {
        let stripped = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
        guard stripped.count == 32, stripped.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }) else { return nil }
        var result = Data()
        var i = stripped.startIndex
        while i < stripped.endIndex {
            let end = stripped.index(i, offsetBy: 2)
            guard let b = UInt8(stripped[i..<end], radix: 16) else { return nil }
            result.append(b)
            i = end
        }
        return result
    }
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func fromB64url(_ text: String) -> Data? {
        let raw = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - raw.count % 4) % 4)
        return Data(base64Encoded: raw + padding)
    }
    static func validate(_ profile: ClearKeyProfile) throws {
        guard let url = URL(string: profile.streamURL), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { throw ClearKeyFailure.invalidStreamURL }
        if !profile.keyID.isEmpty && bytes(hex: profile.keyID) == nil { throw ClearKeyFailure.invalidKeyID }
        if profile.method == "Manual key" {
            guard bytes(hex: profile.keyHex) != nil else { throw ClearKeyFailure.invalidKey }
        } else if profile.method == "License server" {
            guard bytes(hex: profile.keyID) != nil else { throw ClearKeyFailure.invalidKeyID }
            guard let endpoint = URL(string: profile.licenseServer),
                  endpoint.scheme?.lowercased() == "https", endpoint.host != nil else { throw ClearKeyFailure.invalidLicenseURL }
        } else { throw ClearKeyFailure.invalidServerResponse }
    }
    // W3C ClearKey license response: {"keys":[{"kty":"oct","kid":"...","k":"..."}],"type":"temporary"}.
    static func key(fromJWKS payload: Data, wantedKID: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let keys = json["keys"] as? [[String: Any]] else { throw ClearKeyFailure.invalidServerResponse }
        for entry in keys {
            guard (entry["kty"] as? String) == "oct", let kid = entry["kid"] as? String,
                  let kidBytes = fromB64url(kid), kidBytes == wantedKID else { continue }
            guard let b64 = entry["k"] as? String,
                  let bytes = fromB64url(b64), bytes.count == 16 else { throw ClearKeyFailure.invalidServerResponse }
            return hex(bytes)
        }
        throw ClearKeyFailure.noMatchingKey
    }
}

@MainActor final class ClearKeyVault: ObservableObject {
    static let shared = ClearKeyVault()
    @Published private(set) var profiles: [ClearKeyProfile] = []
    private let service = "com.streamlounge.tv.clearkey-profiles.v1"
    private let account = "profiles"
    private init() { read() }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private func read() {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let saved = try? JSONDecoder().decode([ClearKeyProfile].self, from: data) {
            profiles = saved
        }
    }
    private func persist(_ new: [ClearKeyProfile]) throws {
        let data = try JSONEncoder().encode(new)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else if existing == errSecItemNotFound {
            status = SecItemAdd(add as CFDictionary, nil)
        } else { status = existing }
        guard status == errSecSuccess else { throw ClearKeyFailure.storageFailure(status) }
        profiles = new
    }
    func profile(for stream: String) -> ClearKeyProfile? {
        profiles.first { $0.streamURL == stream }
    }
    func enabled(for stream: String) -> ClearKeyProfile? {
        profiles.first { $0.streamURL == stream && $0.enabled }
    }
    func save(_ profile: ClearKeyProfile) throws {
        try ClearKeyCodec.validate(profile)
        var all = profiles.filter { $0.streamURL != profile.streamURL }
        all.append(profile)
        try persist(all.sorted { $0.streamURL < $1.streamURL })
    }
    func remove(stream: String) throws {
        try persist(profiles.filter { $0.streamURL != stream })
    }
}

enum ClearKeyLicenseService {
    // We never send decryption keys to a server: only the 16-byte requested KID.
    // Response keys are used in memory and are not written to logs or plain UserDefaults.
    static func resolve(_ profile: ClearKeyProfile) async throws -> String {
        try ClearKeyCodec.validate(profile)
        if profile.method == "Manual key" {
            guard let key = ClearKeyCodec.bytes(hex: profile.keyHex) else { throw ClearKeyFailure.invalidKey }
            return ClearKeyCodec.hex(key)
        }
        guard let kid = ClearKeyCodec.bytes(hex: profile.keyID),
              let url = URL(string: profile.licenseServer) else { throw ClearKeyFailure.invalidKeyID }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "kids": [ClearKeyCodec.b64url(kid)], "type": "temporary"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClearKeyFailure.invalidServerResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClearKeyFailure.httpError(http.statusCode) }
        guard data.count <= 256 * 1024 else { throw ClearKeyFailure.invalidServerResponse }
        return try ClearKeyCodec.key(fromJWKS: data, wantedKID: kid)
    }
}

// Accessible from Settings and Now Playing. ClearKey is attempted only for
// supported CENC/AES-CTR media when KSPlayer uses its FFmpeg demuxer.
struct ClearKeyEditor: View {
    let streamURL: String
    var onSaved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var method = "Manual key"
    @State private var kid = ""
    @State private var key = ""
    @State private var endpoint = ""
    @State private var enabled = true
    @State private var message = ""
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ClearKey playback").font(.largeTitle.bold())
                Text(streamURL).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Text("Only use keys or a license service supplied by a provider that authorizes playback. This is a single-key CENC/AES-CTR test path, not Widevine, PlayReady or FairPlay.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use ClearKey for this stream", isOn: $enabled)
                ConfirmSelection(title: "Key source", selection: $method, options: [
                    ConfirmOption("Manual key", "Manual key"),
                    ConfirmOption("License server", "License server")
                ])
                TextField("Key ID (KID) — 32 hexadecimal characters", text: $kid)
                    .textInputAutocapitalization(.never)
                if method == "Manual key" {
                    SecureField("Content key — 32 hexadecimal characters", text: $key)
                    Text("The content key is stored in the Apple TV Keychain, not in the playlist or GitHub repository.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("HTTPS ClearKey license-server URL", text: $endpoint)
                        .textInputAutocapitalization(.never)
                    Text("Server must accept a W3C ClearKey JSON POST and return a JWKS key for this KID. No cookies or provider-specific authentication are implemented.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundStyle(.yellow).font(.caption) }
                HStack(spacing: 20) {
                    Button("Save") { save() }.disabled(loading)
                    Button("Remove saved configuration") { remove() }.disabled(loading)
                    Button("Cancel") { dismiss() }
                }
            }
            .padding(64).frame(maxWidth: 1150, alignment: .leading)
        }
        .onAppear {
            guard let profile = ClearKeyVault.shared.profile(for: streamURL) else { return }
            method = profile.method
            kid = profile.keyID
            key = profile.keyHex
            endpoint = profile.licenseServer
            enabled = profile.enabled
        }
    }
    private func save() {
        loading = true
        defer { loading = false }
        let profile = ClearKeyProfile(streamURL: streamURL, method: method,
                                      keyID: kid.trimmingCharacters(in: .whitespacesAndNewlines),
                                      keyHex: key.trimmingCharacters(in: .whitespacesAndNewlines),
                                      licenseServer: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                                      enabled: enabled)
        do {
            try ClearKeyVault.shared.save(profile)
            onSaved()
            dismiss()
        } catch { message = error.localizedDescription }
    }
    private func remove() {
        do {
            try ClearKeyVault.shared.remove(stream: streamURL)
            onSaved()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}

struct ClearKeySettingsPanel: View {
    var entryFocus: FocusState<HomeFocus?>.Binding
    @ObservedObject private var vault = ClearKeyVault.shared
    @State private var newStream = ""
    @State private var editingURL: String?
    @State private var warning = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage authorized ClearKey streams").font(.headline)
            Text("Configure one stream URL at a time. From Now Playing, choose Player → ClearKey to configure the current channel directly. Keys are saved to tvOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Stream URL (https://…/manifest.mpd)", text: $newStream)
                .focused(entryFocus, equals: .settingsOption)
            Button("Configure stream") {
                let entered = newStream.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: entered), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    editingURL = entered
                    warning = ""
                } else { warning = "Enter a valid HTTP or HTTPS stream URL." }
            }
            if !warning.isEmpty { Text(warning).foregroundStyle(.yellow) }
            if vault.profiles.isEmpty { Text("No ClearKey configurations saved.").foregroundStyle(.secondary) }
            ForEach(vault.profiles) { p in
                Button {
                    editingURL = p.streamURL
                } label: {
                    VStack(alignment: .leading) {
                        Text(URL(string: p.streamURL)?.host ?? "Configured stream")
                        Text("\(p.method) · \(p.enabled ? "Enabled" : "Disabled")")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: Binding(
            get: { editingURL.map { ClearKeyTarget(url: $0) } },
            set: { editingURL = $0?.url }
        )) { target in ClearKeyEditor(streamURL: target.url) }
    }
    private struct ClearKeyTarget: Identifiable { var url: String; var id: String { url } }
}
