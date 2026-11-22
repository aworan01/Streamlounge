import SwiftUI

/// Watched web homepage is not a playable media endpoint. This screen does not
/// scrape websites, inject cookies, evade Cloudflare or pretend a private API exists.
/// Users can connect an *authorized* provider-supplied M3U URL for native playback.
struct WatchedNativeConnectView: View {
    @ObservedObject var library: Library
    var openPlaylists: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = "Watched"
    @State private var feedURL = ""
    @State private var message = ""
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                Text("Watched — native playback").font(.largeTitle.bold())
                Text("Service: https://watched.cx/home").font(.caption).foregroundStyle(.secondary)
                Text("Stream Lounge TV can play provider-authorized M3U/HLS/DASH streams using its native tvOS players. Watched's web homepage is not an M3U feed, and an authenticated website session does not itself provide a native player API.")
                .foregroundStyle(.secondary)
                Text("Enter an M3U playlist URL issued by your provider. The app will import it and use AVPlayer, VLC or KSPlayer for playback. It will not open a browser.")
                TextField("Playlist display name",text:$displayName)
                TextField("Provider-supplied M3U URL",text:$feedURL)
                if !message.isEmpty {Text(message).foregroundStyle(.yellow)}
                if !library.message.isEmpty {Text(library.message).font(.caption).foregroundStyle(.secondary)}
                HStack(spacing:18) {
                    Button("Cancel"){dismiss()}
                    Button("Connect native playlist") {
                        Task { await connect() }
                    }.disabled(library.busy)
                    Button("Import an M3U file instead") {
                        dismiss()
                        openPlaylists()
                    }
                }
                if library.busy {ProgressView()}
                Text("If Watched only provides website login without an official API or exportable M3U/Xtream feed, native catalogue browsing and playback cannot be implemented from the homepage URL alone. Cloudflare verification is not bypassed.")
                .font(.caption).foregroundStyle(.secondary)
            }.padding(60).frame(maxWidth:1350,alignment:.leading)
        }
    }
    @MainActor private func connect() async {
        let trimmed=feedURL.trimmingCharacters(in:.whitespacesAndNewlines)
        let name=displayName.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty && name.count<=80 else {message="Enter a playlist name of 1–80 characters.";return}
        guard let url=httpURL(trimmed) else {message="Enter a valid HTTPS M3U feed URL issued by your provider.";return}
        if ["watched.cx", "www.watched.cx"].contains(url.host?.lowercased() ?? "") && ["/home","/live","/"].contains(url.path) {
            message="That URL is a website page, not a playlist. Ask the provider for a native M3U/API endpoint."
            return
        }
        message=""
        let source=Source(name:name,address:trimmed,type:"M3U URL")
        if await library.load(source) {dismiss();openPlaylists()}
        else {message=library.message}
    }
}
