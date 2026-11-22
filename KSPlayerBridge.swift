import UIKit

// This bridge is compiled only for the experimental KSPlayer build.
// IOSVideoPlayerView is gated by canImport(CallKit) in KSPlayer 5.6.2
// and cannot be used on tvOS. VideoPlayerView is supported on tvOS.
#if canImport(KSPlayer) && canImport(KSPlayerUI)
import KSPlayer
import KSPlayerUI

@MainActor final class KSPlayerBridge {
    private(set) var view: VideoPlayerView = VideoPlayerView(frame: .zero)

    init() {
        KSOptions.secondPlayerType = KSMEPlayer.self
        configureView()
    }

    private func configureView() {
        view.backgroundColor = UIColor.black
        view.isUserInteractionEnabled = true
    }

    func open(_ url: URL) {
        // In KSPlayer 5.6.2 set(url:) requires a KSOptions argument.
        view.set(url: url, options: KSOptions())
        view.play()
    }

    func detach() {
        view.removeFromSuperview()
    }

    func close() {
        view.pause()
        view.resetPlayer()
        view.removeFromSuperview()
        view = VideoPlayerView(frame: .zero)
        configureView()
    }
}
#endif
