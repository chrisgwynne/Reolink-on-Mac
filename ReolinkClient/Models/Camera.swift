import Foundation

/// Represents a single Reolink camera the user has configured.
///
/// The model intentionally does **not** store the password. Credentials are kept
/// in the Keychain and looked up via ``KeychainService`` using the camera's
/// ``id``. This keeps secrets out of `UserDefaults`, logs, and any encoded JSON.
struct Camera: Identifiable, Codable, Hashable {
    /// Stable identifier used both as the SwiftUI identity and the Keychain account key.
    let id: UUID

    /// User-facing display name, e.g. "Front Door".
    var name: String

    /// Hostname or IP address on the local network.
    var host: String

    /// HTTP(S) API port. Reolink defaults to 80 (HTTP) or 443 (HTTPS).
    var port: Int

    /// RTSP port. Reolink defaults to 554.
    var rtspPort: Int

    /// Username for the camera's web/API account.
    var username: String

    /// Whether the HTTP API should be reached over TLS.
    var useHTTPS: Bool

    /// Which RTSP stream to show by default in the grid.
    var preferredStream: StreamQuality

    /// Whether this is a mock camera used for development without hardware.
    var isMock: Bool

    /// Capabilities discovered after a successful login. Defaults to a
    /// conservative set until the camera reports otherwise.
    var capabilities: CameraCapabilities

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 80,
        rtspPort: Int = 554,
        username: String,
        useHTTPS: Bool = false,
        preferredStream: StreamQuality = .sub,
        isMock: Bool = false,
        capabilities: CameraCapabilities = .init()
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.rtspPort = rtspPort
        self.username = username
        self.useHTTPS = useHTTPS
        self.preferredStream = preferredStream
        self.isMock = isMock
        self.capabilities = capabilities
    }

    /// Base URL for the HTTP API (`http(s)://host:port`).
    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = useHTTPS ? "https" : "http"
        components.host = host
        components.port = port
        return components.url
    }
}

/// Quality/identity of an RTSP stream offered by the camera.
enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case main
    case sub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .main: return "Main (HD)"
        case .sub: return "Sub (SD)"
        }
    }
}

/// Feature flags describing what a particular camera model supports.
///
/// Populated from the camera's `GetAbility` response when available, but kept
/// permissive so the UI degrades gracefully on unknown models.
struct CameraCapabilities: Codable, Hashable {
    var supportsPTZ: Bool
    var supportsZoom: Bool
    var supportsEvents: Bool
    var supportsPlayback: Bool

    init(
        supportsPTZ: Bool = false,
        supportsZoom: Bool = false,
        supportsEvents: Bool = true,
        supportsPlayback: Bool = false
    ) {
        self.supportsPTZ = supportsPTZ
        self.supportsZoom = supportsZoom
        self.supportsEvents = supportsEvents
        self.supportsPlayback = supportsPlayback
    }
}

extension Camera {
    /// A deterministic mock camera for development without real hardware.
    static func mock(
        name: String = "Mock Camera",
        id: UUID = UUID()
    ) -> Camera {
        Camera(
            id: id,
            name: name,
            host: "127.0.0.1",
            username: "admin",
            isMock: true,
            capabilities: CameraCapabilities(
                supportsPTZ: true,
                supportsZoom: true,
                supportsEvents: true,
                supportsPlayback: true
            )
        )
    }
}
