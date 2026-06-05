import Foundation

/// Async client for the Reolink CGI HTTP API.
///
/// Reolink devices expose a JSON-over-HTTP API at `/cgi-bin/api.cgi`. Most
/// commands are issued as a `POST` with a JSON array body and a `cmd` query
/// item, authenticated by a login token obtained from the `Login` command.
///
/// The client is an `actor` so token state is mutated safely from concurrent
/// callers, and it never logs credentials or tokens.
actor ReolinkAPIClient {

    // MARK: Errors

    enum APIError: LocalizedError {
        case invalidURL
        case transport(underlying: Error)
        case httpStatus(Int)
        case decoding(underlying: Error)
        case apiFailure(code: Int, detail: String?)
        case notLoggedIn
        case unsupported

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The camera address is invalid."
            case .transport(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .httpStatus(let code):
                return "The camera returned HTTP status \(code)."
            case .decoding:
                return "The camera returned an unexpected response."
            case .apiFailure(let code, let detail):
                if let detail, !detail.isEmpty {
                    return "Camera error \(code): \(detail)"
                }
                return "Camera error \(code)."
            case .notLoggedIn:
                return "Not authenticated with the camera."
            case .unsupported:
                return "This command is not supported by the camera."
            }
        }
    }

    // MARK: State

    private let camera: Camera
    private let session: URLSession
    private var token: String?
    private var tokenExpiry: Date?

    init(camera: Camera, session: URLSession = .reolinkDefault) {
        self.camera = camera
        self.session = session
    }

    // MARK: Public API

    /// Authenticate and store a token. Returns the token's lease time in seconds.
    /// Pass the password explicitly so it is never persisted on the client.
    @discardableResult
    func login(password: String) async throws -> TimeInterval {
        if camera.isMock {
            token = "mock-token"
            tokenExpiry = Date().addingTimeInterval(3600)
            return 3600
        }

        let loginParam: [String: Any] = [
            "User": [
                "userName": camera.username,
                "password": password
            ]
        ]
        let body: [[String: Any]] = [[
            "cmd": "Login",
            "param": loginParam
        ]]

        let json = try await rawRequest(cmd: "Login", body: body, includeToken: false)
        guard
            let first = json.first,
            let value = first["value"] as? [String: Any],
            let tokenObj = value["Token"] as? [String: Any],
            let name = tokenObj["name"] as? String
        else {
            try Self.throwIfAPIError(json)
            throw APIError.decoding(underlying: DecodingPlaceholder())
        }

        let lease = (tokenObj["leaseTime"] as? Double) ?? 3600
        token = name
        tokenExpiry = Date().addingTimeInterval(lease)
        return lease
    }

    /// Lightweight connectivity + credential check used by the "Test Connection"
    /// button. Logs in, then queries device info. Throws on any failure.
    func testConnection(password: String) async throws -> DeviceInfo {
        try await login(password: password)
        return try await deviceInfo()
    }

    /// Fetch basic device information (model, firmware, name).
    func deviceInfo() async throws -> DeviceInfo {
        if camera.isMock {
            return DeviceInfo(model: "Mock RLC-9999", firmware: "v1.0.0-mock", name: camera.name)
        }
        let json = try await command(cmd: "GetDevInfo", param: ["channel": 0])
        guard
            let value = json["value"] as? [String: Any],
            let info = value["DevInfo"] as? [String: Any]
        else {
            throw APIError.decoding(underlying: DecodingPlaceholder())
        }
        return DeviceInfo(
            model: info["model"] as? String ?? "Unknown",
            firmware: info["firmVer"] as? String ?? "Unknown",
            name: info["name"] as? String ?? camera.name
        )
    }

    /// Discover camera capabilities (PTZ, zoom, events, playback).
    func fetchCapabilities() async throws -> CameraCapabilities {
        if camera.isMock {
            return CameraCapabilities(
                supportsPTZ: true, supportsZoom: true,
                supportsEvents: true, supportsPlayback: true
            )
        }

        let json = try await command(
            cmd: "GetAbility",
            param: ["User": ["userName": camera.username]]
        )
        guard
            let value = json["value"] as? [String: Any],
            let ability = value["Ability"] as? [String: Any]
        else {
            // Unknown shape — fall back to conservative defaults.
            return CameraCapabilities()
        }

        // Per-channel abilities live under "abilityChn".
        let channelAbility = (ability["abilityChn"] as? [[String: Any]])?.first ?? [:]

        func permitted(_ key: String, in dict: [String: Any]) -> Bool {
            guard let entry = dict[key] as? [String: Any],
                  let permit = entry["permit"] as? Int else { return false }
            return permit > 0
        }

        let ptz = permitted("ptzCtrl", in: channelAbility) || permitted("ptzType", in: channelAbility)
        let zoom = permitted("ptzCtrl", in: channelAbility)
        let playback = permitted("recCfg", in: channelAbility) || permitted("playback", in: channelAbility)
        let events = permitted("alarmMd", in: channelAbility) || permitted("mdWithPicture", in: channelAbility)

        return CameraCapabilities(
            supportsPTZ: ptz,
            supportsZoom: zoom,
            supportsEvents: events || true,   // motion is near-universal
            supportsPlayback: playback
        )
    }

    /// Capture a JPEG snapshot from the camera.
    func snapshot() async throws -> Data {
        if camera.isMock {
            return MockMedia.snapshotJPEG(label: camera.name)
        }
        try ensureToken()
        guard var components = urlComponents(path: "/cgi-bin/api.cgi") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "cmd", value: "Snap"),
            URLQueryItem(name: "channel", value: "0"),
            URLQueryItem(name: "rs", value: UUID().uuidString),
            URLQueryItem(name: "token", value: token)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        do {
            let (data, response) = try await session.data(from: url)
            try Self.validate(response)
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(underlying: error)
        }
    }

    /// Issue a PTZ operation. `speed` is 1–64; `op` examples: "Up", "Down",
    /// "Left", "Right", "Stop", "ZoomInc", "ZoomDec".
    func ptz(operation op: PTZOperation, speed: Int = 16) async throws {
        guard camera.capabilities.supportsPTZ else { throw APIError.unsupported }
        if camera.isMock { return }
        try ensureToken()
        _ = try await command(
            cmd: "PtzCtrl",
            param: [
                "channel": 0,
                "op": op.rawValue,
                "speed": min(max(speed, 1), 64)
            ]
        )
    }

    /// Fetch detection events for a given local day.
    func events(on day: Date, calendar: Calendar = .current) async throws -> [CameraEvent] {
        if camera.isMock {
            return MockMedia.events(for: camera.id, on: day)
        }
        guard camera.capabilities.supportsEvents else { return [] }
        try ensureToken()

        let startOfDay = calendar.startOfDay(for: day)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            return []
        }

        let search: [String: Any] = [
            "channel": 0,
            "onlyStatus": 0,
            "streamType": "main",
            "StartTime": Self.timeDict(from: startOfDay, calendar: calendar),
            "EndTime": Self.timeDict(from: endOfDay, calendar: calendar)
        ]
        let json = try await command(cmd: "Search", param: ["Search": search])

        guard
            let value = json["value"] as? [String: Any],
            let searchResult = value["SearchResult"] as? [String: Any],
            let files = searchResult["File"] as? [[String: Any]]
        else {
            return []
        }

        return files.compactMap { file -> CameraEvent? in
            guard
                let start = file["StartTime"] as? [String: Any],
                let end = file["EndTime"] as? [String: Any],
                let startDate = Self.date(from: start, calendar: calendar),
                let endDate = Self.date(from: end, calendar: calendar)
            else { return nil }

            return CameraEvent(
                cameraID: camera.id,
                kind: Self.eventKind(from: file["type"] as? String),
                startTime: startDate,
                endTime: endDate,
                hasRecording: true
            )
        }
    }

    // MARK: - Request plumbing

    /// Issue a single command and return its decoded JSON object (the first
    /// element of the response array). Throws on API-level error codes.
    private func command(cmd: String, param: [String: Any]) async throws -> [String: Any] {
        let body: [[String: Any]] = [["cmd": cmd, "param": param]]
        let json = try await rawRequest(cmd: cmd, body: body, includeToken: true)
        try Self.throwIfAPIError(json)
        guard let first = json.first else {
            throw APIError.decoding(underlying: DecodingPlaceholder())
        }
        return first
    }

    /// Perform the HTTP POST and return the decoded top-level JSON array.
    private func rawRequest(
        cmd: String,
        body: [[String: Any]],
        includeToken: Bool
    ) async throws -> [[String: Any]] {
        guard var components = urlComponents(path: "/cgi-bin/api.cgi") else {
            throw APIError.invalidURL
        }
        var query = [URLQueryItem(name: "cmd", value: cmd)]
        if includeToken {
            try ensureToken()
            query.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = query
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw APIError.decoding(underlying: DecodingPlaceholder())
            }
            return parsed
        } catch let error as APIError {
            throw error
        } catch let error as DecodingPlaceholder {
            throw APIError.decoding(underlying: error)
        } catch {
            throw APIError.transport(underlying: error)
        }
    }

    private func ensureToken() throws {
        guard let token, !token.isEmpty else { throw APIError.notLoggedIn }
        if let tokenExpiry, tokenExpiry < Date() {
            self.token = nil
            throw APIError.notLoggedIn
        }
    }

    private func urlComponents(path: String) -> URLComponents? {
        guard let base = camera.baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        return components
    }

    // MARK: - Static helpers

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode)
        }
    }

    /// Inspect a Reolink response for an embedded `error` object and throw.
    private static func throwIfAPIError(_ json: [[String: Any]]) throws {
        for entry in json {
            if let error = entry["error"] as? [String: Any] {
                let code = (error["rspCode"] as? Int) ?? -1
                let detail = error["detail"] as? String
                throw APIError.apiFailure(code: code, detail: detail)
            }
        }
    }

    private static func eventKind(from raw: String?) -> EventKind {
        switch raw?.lowercased() {
        case let s? where s.contains("person"): return .person
        case let s? where s.contains("vehicle"): return .vehicle
        case let s? where s.contains("animal") || (raw?.lowercased().contains("dog") ?? false):
            return .animal
        case let s? where s.contains("md") || s.contains("motion"): return .motion
        default: return .other
        }
    }

    private static func timeDict(from date: Date, calendar: Calendar) -> [String: Int] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return [
            "year": c.year ?? 1970, "mon": c.month ?? 1, "day": c.day ?? 1,
            "hour": c.hour ?? 0, "min": c.minute ?? 0, "sec": c.second ?? 0
        ]
    }

    private static func date(from dict: [String: Any], calendar: Calendar) -> Date? {
        var c = DateComponents()
        c.year = dict["year"] as? Int
        c.month = dict["mon"] as? Int
        c.day = dict["day"] as? Int
        c.hour = dict["hour"] as? Int
        c.minute = dict["min"] as? Int
        c.second = dict["sec"] as? Int
        return calendar.date(from: c)
    }
}

/// Basic device metadata returned by `GetDevInfo`.
struct DeviceInfo: Equatable {
    let model: String
    let firmware: String
    let name: String
}

/// Supported PTZ operations mapped to Reolink `op` values.
enum PTZOperation: String {
    case up = "Up"
    case down = "Down"
    case left = "Left"
    case right = "Right"
    case stop = "Stop"
    case zoomIn = "ZoomInc"
    case zoomOut = "ZoomDec"
}

/// Marker error used when JSON does not match the expected shape.
private struct DecodingPlaceholder: Error {}

extension URLSession {
    /// A session tuned for talking to cameras on a LAN: short timeouts, no
    /// caching of responses, and waits for connectivity disabled so failures
    /// surface quickly for reconnect logic.
    static let reolinkDefault: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
