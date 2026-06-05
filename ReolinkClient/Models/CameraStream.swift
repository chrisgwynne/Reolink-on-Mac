import Foundation

/// Describes a concrete RTSP stream endpoint for a camera.
///
/// Produced by ``RTSPURLBuilder``. The struct deliberately exposes the URL via
/// ``redactedDescription`` for logging so credentials never reach the console.
struct CameraStream: Identifiable, Hashable {
    let id: UUID
    let cameraID: UUID
    let quality: StreamQuality

    /// The fully-formed RTSP URL including credentials. Treat as a secret.
    let url: URL

    init(cameraID: UUID, quality: StreamQuality, url: URL) {
        self.id = UUID()
        self.cameraID = cameraID
        self.quality = quality
        self.url = url
    }

    /// A version of the URL safe to print to logs (credentials stripped).
    var redactedDescription: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "rtsp://<redacted>"
        }
        if components.user != nil { components.user = "***" }
        if components.password != nil { components.password = "***" }
        return components.string ?? "rtsp://<redacted>"
    }
}

/// Connection state for a live stream, surfaced to the UI.
enum StreamState: Equatable {
    case idle
    case connecting
    case buffering
    case playing
    case reconnecting(attempt: Int)
    case stalled
    case failed(message: String, canRetry: Bool)

    /// True while the pipeline is doing something (prevents duplicate starts).
    var isActive: Bool {
        switch self {
        case .connecting, .buffering, .playing, .reconnecting, .stalled:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// True only when frames are actually rendering.
    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// True when the user should be offered a Retry action.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .buffering: return "Buffering…"
        case .playing: return "Live"
        case .reconnecting(let attempt): return "Retrying (\(attempt))…"
        case .stalled: return "Stalled — recovering…"
        case .failed(let message, _): return message
        }
    }
}
