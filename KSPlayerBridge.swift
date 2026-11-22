import UIKit

// This module is compiled into both builds. It is activated only in the
// separate KSPlayer experimental build, which links the KSPlayerUI package.
#if canImport(KSPlayer) && canImport(KSPlayerUI)
import KSPlayer
import KSPlayerUI

@MainActor final class KSPlayerBridge {
    private(set) var view=IOSVideoPlayerView()
    init() {
        KSOptions.secondPlayerType = KSMEPlayer.self
        view.backgroundColor = .black
        view.isUserInteractionEnabled = true
    }
    func open(_ url: URL) {view.set(url:url)}
    func detach() {view.removeFromSuperview()}
    func close() {
        view.removeFromSuperview()
        // Dropping the owning view lets the framework dispose the old player.
        view=IOSVideoPlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = true
    }
}
#endif
