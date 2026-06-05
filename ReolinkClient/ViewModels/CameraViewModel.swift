import Foundation
import AppKit
import Combine

/// Drives a single camera's live view, snapshots, PTZ, and events.
///
/// One instance is created per visible camera tile/detail view. It owns the
/// ``ReolinkAPIClient`` and exposes published state for SwiftUI. Reconnect uses
/// exponential backoff and is cancelled cleanly when the view disappears.
@MainActor
final class CameraViewModel: ObservableObject {
    let camera: Camera

    @Published var streamState: StreamState = .idle
    @Published var stream: CameraStream?
    @Published var snapshotInProgress = false
    @Published var lastError: String?
    @Published var deviceInfo: DeviceInfo?
    @Published var events: [CameraEvent] = []
    @Published var loadingEvents = false

    /// Currently selected stream quality (Main/Sub). Drives the quality selector.
    @Published private(set) var activeQuality: StreamQuality

    /// What the player is currently showing: the live feed or a recorded clip.
    @Published private(set) var source: PlaybackSource = .live

    /// Whether playback is paused (recorded clips). Observed by the player view.
    @Published private(set) var isPaused = false

    private let store: CameraStore
    private let api: ReolinkAPIClient

    // Reconnect / stall handling.
    private var reconnectTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private let maxReconnectAttempts = 6
    /// Seconds allowed to reach `.playing` before a connect is judged stalled.
    private let stallTimeout: TimeInterval = 12

    // Candidate RTSP URLs for the active quality, in priority order
    // (modern `Preview_*` first, legacy `h264Preview_*` as fallback).
    private var candidateURLs: [URL] = []
    private var candidateIndex = 0
    private var reconnectAttempt = 0
    /// Whether we ever reached `.playing` this session — distinguishes a dropped
    /// connection (reconnect) from a never-worked connection (classify + fail).
    private var hasEverPlayed = false

    init(camera: Camera, store: CameraStore) {
        self.camera = camera
        self.store = store
        self.api = ReolinkAPIClient(camera: camera)
        self.activeQuality = camera.preferredStream
    }

    // MARK: - Live view lifecycle

    /// Prepare candidate URLs and begin playback. Idempotent while active.
    func start(quality: StreamQuality? = nil) {
        guard !streamState.isActive else { return }
        if let quality { activeQuality = quality }
        beginPlayback(resetState: true)
    }

    /// Stop playback, clear the stream, and cancel all timers. Leaves the engine
    /// reusable (the player view keeps a single VLC instance per tile).
    func stop() {
        cancelTimers()
        candidateURLs = []
        candidateIndex = 0
        reconnectAttempt = 0
        hasEverPlayed = false
        isPaused = false
        stream = nil
        streamState = .idle
    }

    /// Stop and immediately restart the current stream (manual refresh). Works
    /// even when the URL is unchanged because each restart mints a new stream id.
    func refresh() {
        let quality = activeQuality
        stop()
        start(quality: quality)
    }

    /// User-initiated retry from the error state. Replays whatever the current
    /// source is — the live feed or the recorded clip.
    func retry() {
        switch source {
        case .live:
            stop()
            start()
        case .recording(let event):
            playEvent(event)
        }
    }

    // MARK: - Recorded event playback

    /// Play a recorded clip for `event` through the same player/engine used for
    /// live view. No second engine is created — only the stream URL changes.
    func playEvent(_ event: CameraEvent) {
        guard event.hasRecording else {
            streamState = .failed(message: "No recording is available for this event.", canRetry: false)
            return
        }
        cancelTimers()
        source = .recording(event)
        isPaused = false
        reconnectAttempt = 0
        candidateIndex = 0
        hasEverPlayed = false
        lastError = nil
        streamState = .connecting

        if camera.isMock {
            stream = nil
            hasEverPlayed = true
            streamState = .playing
            return
        }

        guard let name = event.recordingName else {
            streamState = .failed(message: "Recording reference unavailable.", canRetry: false)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let password = try self.store.password(for: self.camera) ?? ""
                try await self.api.login(password: password)
                let url = try await self.api.playbackURL(forRecording: name)
                self.candidateURLs = [url]
                self.candidateIndex = 0
                self.playCurrentCandidate()
            } catch {
                self.streamState = .failed(message: error.localizedDescription, canRetry: true)
            }
        }
    }

    /// Pause or resume the current recorded clip.
    func togglePause() {
        guard case .recording = source else { return }
        guard streamState.isPlaying || isPaused else { return }
        isPaused.toggle()
    }

    /// Stop any recorded playback and return to the live feed.
    func returnToLive() {
        stop()
        source = .live
        start()
    }

    /// The engine reached the natural end of the media.
    func playerDidEnd() {
        switch source {
        case .live:
            // A live RTSP feed shouldn't "end"; treat as a drop and reconnect.
            handleProblem(reason: "Stream ended", isStall: false)
        case .recording:
            // A recorded clip finished playing — stop cleanly and offer replay.
            cancelTimers()
            isPaused = false
            stream = nil
            streamState = .idle
        }
    }

    /// Switch between Main and Sub streams without restarting the app. The player
    /// swaps media in place; no-op if already on the requested quality.
    func switchQuality(to quality: StreamQuality) {
        guard quality != activeQuality else { return }
        activeQuality = quality
        guard !camera.isMock else { return }
        beginPlayback(resetState: true)
    }

    // MARK: - Player callbacks (from RTSPPlayerView)

    /// Frames are flowing: clear timers and lock in the working URL.
    func playerDidStart() {
        cancelTimers()
        hasEverPlayed = true
        reconnectAttempt = 0
        streamState = .playing
    }

    /// Opening/buffering before the first frame. Give buffering a fresh stall
    /// window since it represents progress toward playing.
    func playerIsBuffering() {
        if streamState.isPlaying { return }
        if case .connecting = streamState {
            streamState = .buffering
            startWatchdog()
        }
    }

    /// The engine reported an error or end-of-stream.
    func playerDidFail(_ message: String) {
        handleProblem(reason: message, isStall: false)
    }

    // MARK: - Private playback engine

    private func beginPlayback(resetState: Bool) {
        cancelTimers()
        source = .live
        isPaused = false
        if resetState {
            reconnectAttempt = 0
            candidateIndex = 0
            hasEverPlayed = false
        }
        lastError = nil
        streamState = .connecting

        if camera.isMock {
            // Mock streams have no real URL; the player view shows a synthesized
            // frame loop instead and we report "playing" immediately.
            stream = nil
            hasEverPlayed = true
            streamState = .playing
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                self.candidateURLs = try self.buildCandidates(quality: self.activeQuality)
                self.candidateIndex = 0
                self.playCurrentCandidate()
            } catch {
                self.streamState = .failed(message: error.localizedDescription, canRetry: true)
            }
        }
    }

    private func buildCandidates(quality: StreamQuality) throws -> [URL] {
        let password = try store.password(for: camera) ?? ""
        return try RTSPURLBuilder.candidateURLs(for: camera, password: password, quality: quality)
    }

    /// Load the current candidate URL into the player and arm the stall watchdog.
    private func playCurrentCandidate() {
        guard candidateIndex < candidateURLs.count else {
            Task { await finishFailed() }
            return
        }
        let url = candidateURLs[candidateIndex]
        streamState = (reconnectAttempt > 0) ? .reconnecting(attempt: reconnectAttempt) : .connecting
        // A fresh stream id guarantees the player replays even for an identical URL.
        stream = CameraStream(cameraID: camera.id, quality: activeQuality, url: url)
        startWatchdog()
    }

    /// A connect/play problem: try the next candidate URL, else back off & reconnect.
    private func handleProblem(reason: String, isStall: Bool) {
        cancelTimers()
        lastError = reason

        // Recorded playback: no live-style URL fallback or reconnect loop —
        // surface a readable error with Retry (which replays the clip).
        if case .recording = source {
            Task { await finishFailed() }
            return
        }

        // Live: first exhaust alternate URLs (e.g., legacy h264Preview_*).
        if candidateIndex + 1 < candidateURLs.count {
            candidateIndex += 1
            if isStall { streamState = .stalled }
            playCurrentCandidate()
            return
        }

        // All URLs tried → exponential backoff, then start over from the first URL.
        scheduleReconnect(isStall: isStall)
    }

    /// Exponential-backoff reconnect: 1, 2, 4, 8 … seconds, capped at 30s.
    private func scheduleReconnect(isStall: Bool) {
        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            Task { await finishFailed() }
            return
        }
        let attempt = reconnectAttempt
        streamState = isStall ? .stalled : .reconnecting(attempt: attempt)

        let delay = min(pow(2.0, Double(attempt - 1)), 30)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.candidateIndex = 0
            self.playCurrentCandidate()
        }
    }

    /// Arm a one-shot watchdog: if `.playing` isn't reached within `stallTimeout`,
    /// treat the current candidate as stalled and recover.
    private func startWatchdog() {
        let timeout = stallTimeout
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.streamState.isPlaying { return }
            self.handleProblem(reason: "No video within \(Int(timeout))s", isStall: true)
        }
    }

    /// Give up after exhausting URLs + attempts, producing a readable message.
    private func finishFailed() async {
        cancelTimers()
        let message: String
        if hasEverPlayed {
            message = "Connection lost. \(lastError ?? "The stream stopped.")"
        } else {
            message = await classifyConnectFailure()
        }
        stream = nil
        streamState = .failed(message: message, canRetry: true)
    }

    /// Probe the HTTP API to turn an opaque RTSP failure into a useful message
    /// (auth vs. unreachable vs. unsupported stream).
    private func classifyConnectFailure() async -> String {
        do {
            let password = try store.password(for: camera) ?? ""
            try await api.login(password: password)
            // Credentials valid and camera reachable → the RTSP stream itself failed.
            return "Stream unavailable — this camera may not offer RTSP at the expected URL."
        } catch let error as ReolinkAPIClient.APIError {
            switch error {
            case .apiFailure, .notLoggedIn:
                return "Authentication failed — check the username and password."
            case .httpStatus(let code):
                return "Camera returned HTTP \(code) — check the port and credentials."
            case .transport, .invalidURL:
                return "Camera unreachable — check the address and network."
            default:
                return error.localizedDescription
            }
        } catch {
            return "Camera unreachable — check the address and network."
        }
    }

    private func cancelTimers() {
        watchdogTask?.cancel(); watchdogTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
    }

    // MARK: - Snapshot

    /// Capture a snapshot and save it under Pictures/Reolink Snapshots.
    /// Returns the saved file URL on success.
    @discardableResult
    func captureSnapshot() async -> URL? {
        snapshotInProgress = true
        defer { snapshotInProgress = false }
        do {
            let data = try await api.snapshot()
            let url = try SnapshotStore.save(data, cameraName: camera.name)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - PTZ

    func ptz(_ operation: PTZOperation) async {
        guard camera.capabilities.supportsPTZ else { return }
        do {
            try await api.ptz(operation: operation)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Device info & capabilities

    func refreshDeviceInfo() async {
        do {
            let password = try store.password(for: camera) ?? ""
            try await api.login(password: password)
            deviceInfo = try await api.deviceInfo()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Events

    func loadEvents(on day: Date) async {
        guard camera.capabilities.supportsEvents else { return }
        loadingEvents = true
        defer { loadingEvents = false }
        do {
            if !camera.isMock {
                let password = try store.password(for: camera) ?? ""
                try await api.login(password: password)
            }
            events = try await api.events(on: day)
        } catch {
            lastError = error.localizedDescription
            events = []
        }
    }

    deinit {
        reconnectTask?.cancel()
        watchdogTask?.cancel()
    }
}
