import Foundation

/// Builds Reolink RTSP URLs for a camera's main and sub streams.
///
/// Reolink exposes two common URL schemes. The newer `Preview` form works
/// across most current firmware:
///
///     rtsp://user:pass@host:554/Preview_01_main
///     rtsp://user:pass@host:554/Preview_01_sub
///
/// Older models use the `h264Preview` form:
///
///     rtsp://user:pass@host:554/h264Preview_01_main
///     rtsp://user:pass@host:554/h264Preview_01_sub
///
/// We default to the `Preview` form and expose the legacy builder as a fallback
/// the UI/player can try if the first fails.
enum RTSPURLBuilder {

    enum BuilderError: LocalizedError {
        case invalidComponents

        var errorDescription: String? {
            switch self {
            case .invalidComponents:
                return "Could not construct a valid RTSP URL from the camera settings."
            }
        }
    }

    /// Channel number for single-lens cameras. Multi-channel NVRs would vary this.
    static let defaultChannel = 1

    /// Build the primary (modern firmware) RTSP URL.
    static func url(
        for camera: Camera,
        password: String,
        quality: StreamQuality,
        channel: Int = defaultChannel
    ) throws -> URL {
        try makeURL(
            camera: camera,
            password: password,
            path: "/Preview_\(channelString(channel))_\(quality.rawValue)"
        )
    }

    /// Build the legacy (`h264Preview`) RTSP URL used by older models.
    static func legacyURL(
        for camera: Camera,
        password: String,
        quality: StreamQuality,
        channel: Int = defaultChannel
    ) throws -> URL {
        try makeURL(
            camera: camera,
            password: password,
            path: "/h264Preview_\(channelString(channel))_\(quality.rawValue)"
        )
    }

    /// Both candidate URLs in priority order, useful for player fallback.
    static func candidateURLs(
        for camera: Camera,
        password: String,
        quality: StreamQuality,
        channel: Int = defaultChannel
    ) throws -> [URL] {
        [
            try url(for: camera, password: password, quality: quality, channel: channel),
            try legacyURL(for: camera, password: password, quality: quality, channel: channel)
        ]
    }

    // MARK: - Private

    private static func channelString(_ channel: Int) -> String {
        // Reolink channels are 1-based and zero-padded to two digits, e.g. "01".
        String(format: "%02d", max(channel, 1))
    }

    private static func makeURL(camera: Camera, password: String, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = camera.host
        components.port = camera.rtspPort
        components.user = camera.username
        components.password = password
        components.path = path

        guard let url = components.url else {
            throw BuilderError.invalidComponents
        }
        return url
    }
}
