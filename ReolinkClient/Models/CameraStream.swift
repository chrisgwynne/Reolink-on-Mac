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
    case playing
    case reconnecting(attempt: Int)
    case failed(message: String)

    var isActive: Bool {
        switch self {
        case .connecting, .playing, .reconnecting:
            return true
        case .idle, .failed:
            return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .playing: return "Live"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))…"
        case .failed(let message): return message
        }
    }
}
