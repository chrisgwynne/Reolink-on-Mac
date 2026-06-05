import Foundation
import AppKit

/// Abstraction over the underlying RTSP playback engine.
///
/// The app is built so it compiles and runs **without** the VLC package (in mock
/// mode or for tooling that lacks the binary). When the `VLCKitSPM` package is
/// linked, the real implementation is compiled in via `#if canImport(VLCKitSPM)`.
/// Otherwise a stub is used that reports a clear "engine not linked" state.
///
/// Each `RTSPPlayerEngine` owns exactly one player, so multiple engines (one per
/// camera tile) drive multiple simultaneous streams independently.
protocol RTSPPlayerEngine: AnyObject {
    /// The view that renders video frames.
    var rendererView: NSView { get }

    /// Begin playback of `url`. Safe to call again with a new URL to switch
    /// sources (live ↔ recorded clip, main ↔ sub) without recreating the engine.
    func play(url: URL)

    /// Pause or resume playback in place (used for recorded clips).
    func setPaused(_ paused: Bool)

    /// Stop playback but keep the engine reusable.
    func stop()

    /// Stop and release all resources. The engine should not be reused after.
    func teardown()

    /// Invoked once the first frames render.
    var onPlaying: (() -> Void)? { get set }

    /// Invoked when buffering/opening, before the first frame.
    var onBuffering: (() -> Void)? { get set }

    /// Invoked when the media reaches its natural end (e.g., a recorded clip
    /// finishes). Distinct from a failure so callers can choose not to reconnect.
    var onEnded: (() -> Void)? { get set }

    /// Invoked on a playback error with a human-readable reason.
    var onFailure: ((String) -> Void)? { get set }
}

#if canImport(VLCKitSPM)
import VLCKitSPM

/// Real engine backed by VLCKit (libVLC) via the `VLCKitSPM` package.
///
/// On Apple Silicon, VLCKit decodes H.264/H.265 through VideoToolbox
/// (hardware) by default, keeping CPU usage low even with several tiles.
final class VLCPlayerWrapper: NSObject, RTSPPlayerEngine, VLCMediaPlayerDelegate {
    private let player = VLCMediaPlayer()
    private let videoView = VLCVideoView()
    private var currentURL: URL?

    var onPlaying: (() -> Void)?
    var onBuffering: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var rendererView: NSView { videoView }

    /// Set while we intentionally stop the player (swap/stop/teardown) so the
    /// resulting `.stopped` notification isn't misreported as a stream drop.
    private var isIntentionallyStopping = false

    override init() {
        super.init()
        player.delegate = self
        player.drawable = videoView
    }

    func play(url: URL) {
        // Switching sources: stop the current media before swapping.
        if player.isPlaying || currentURL != nil {
            isIntentionallyStopping = true
            player.stop()
        }
        currentURL = url

        let media = VLCMedia(url: url)
        // Prefer TCP for RTSP to avoid UDP packet loss on Wi-Fi, keep the network
        // cache small for low latency, and let VLC pick hardware decoding.
        media.addOptions([
            "network-caching": 300,
            "rtsp-tcp": true,
            "clock-jitter": 0,
            "clock-synchro": 0
        ])
        player.media = media
        isIntentionallyStopping = false
        player.play()
    }

    func setPaused(_ paused: Bool) {
        if paused {
            if player.isPlaying { player.pause() }
        } else {
            if !player.isPlaying { player.play() }
        }
    }

    func stop() {
        isIntentionallyStopping = true
        player.stop()
        currentURL = nil
    }

    func teardown() {
        isIntentionallyStopping = true
        player.stop()
        player.delegate = nil
        player.drawable = nil
        currentURL = nil
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .opening, .buffering:
            onBuffering?()
        case .playing:
            onPlaying?()
        case .error:
            onFailure?("Playback error")
        case .ended:
            // Natural end of media (e.g., a recorded clip finished).
            onEnded?()
        case .stopped:
            // Either our own stop (ignore) or, for live RTSP, an unexpected drop.
            if !isIntentionallyStopping, currentURL != nil {
                onFailure?("Stream ended")
            }
        default:
            break
        }
    }
}

#else

/// Stub engine used when the VLC package is not linked. Real RTSP playback is
/// disabled; the view layer shows guidance instead. Mock cameras don't use this.
final class VLCPlayerWrapper: NSObject, RTSPPlayerEngine {
    private let placeholder = NSView()

    var onPlaying: (() -> Void)?
    var onBuffering: (() -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var rendererView: NSView { placeholder }

    func play(url: URL) {
        onFailure?("RTSP engine not linked. Add the VLCKitSPM package to enable live video.")
    }

    func setPaused(_ paused: Bool) {}
    func stop() {}
    func teardown() {}
}

#endif
