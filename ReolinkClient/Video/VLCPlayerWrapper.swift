import Foundation
import AppKit

/// Abstraction over the underlying RTSP playback engine.
///
/// The app is built so it compiles and runs **without** VLCKit (in mock mode or
/// for CI). When the `VLCKit` package is linked, the real implementation is
/// compiled in via `#if canImport(VLCKit)`. Otherwise a stub is used that
/// reports a clear "engine not linked" state.
protocol RTSPPlayerEngine: AnyObject {
    /// The view that renders video frames.
    var rendererView: NSView { get }

    /// Begin playback of `url`. Engine should call the callbacks as state changes.
    func play(url: URL)

    /// Stop playback and release resources.
    func stop()

    /// Invoked once the first frames render.
    var onPlaying: (() -> Void)? { get set }

    /// Invoked on error or end-of-stream with a human-readable reason.
    var onFailure: ((String) -> Void)? { get set }
}

#if canImport(VLCKit)
import VLCKit

/// Real engine backed by VLCKit (libVLC). Add the `VLCKit` Swift package to the
/// app target to enable this path.
final class VLCPlayerWrapper: NSObject, RTSPPlayerEngine, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private let videoView = VLCVideoView()

    var onPlaying: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var rendererView: NSView { videoView }

    override init() {
        super.init()
        player.delegate = self
        player.drawable = videoView
    }

    func play(url: URL) {
        let media = VLCMedia(url: url)
        // Prefer TCP for RTSP to avoid UDP packet loss on Wi-Fi, and keep the
        // network cache small for low latency.
        media.addOptions([
            "network-caching": 300,
            "rtsp-tcp": true
        ])
        player.media = media
        player.play()
    }

    func stop() {
        player.stop()
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .playing:
            onPlaying?()
        case .error:
            onFailure?("Playback error")
        case .ended, .stopped:
            onFailure?("Stream ended")
        default:
            break
        }
    }
}

#else

/// Stub engine used when VLCKit is not linked. Real RTSP playback is disabled;
/// the view layer shows guidance instead. Mock cameras don't use this path.
final class VLCPlayerWrapper: NSObject, RTSPPlayerEngine {
    private let placeholder = NSView()

    var onPlaying: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var rendererView: NSView { placeholder }

    func play(url: URL) {
        onFailure?("RTSP engine not linked. Add the VLCKit package to enable live video.")
    }

    func stop() {}
}

#endif
