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

    private let store: CameraStore
    private let api: ReolinkAPIClient
    private var reconnectTask: Task<Void, Never>?
    private let maxReconnectAttempts = 6

    init(camera: Camera, store: CameraStore) {
        self.camera = camera
        self.store = store
        self.api = ReolinkAPIClient(camera: camera)
    }

    // MARK: - Live view lifecycle

    /// Prepare the stream URL and begin playback. Idempotent.
    func start(quality: StreamQuality? = nil) {
        guard !streamState.isActive else { return }
        let desired = quality ?? camera.preferredStream
        streamState = .connecting
        lastError = nil

        Task {
            do {
                let password = try store.password(for: camera) ?? ""
                if camera.isMock {
                    // Mock streams have no real URL; the player view shows a
                    // synthesized frame loop instead.
                    self.stream = nil
                    self.streamState = .playing
                    return
                }
                let url = try RTSPURLBuilder.url(for: camera, password: password, quality: desired)
                self.stream = CameraStream(cameraID: camera.id, quality: desired, url: url)
                // The RTSPPlayerView reports back via `playerDidStart` /
                // `playerDidFail`; until then we remain "connecting".
            } catch {
                self.handleFailure(error.localizedDescription)
            }
        }
    }

    /// Stop playback and cancel any pending reconnect.
    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        stream = nil
        streamState = .idle
    }

    /// Called by the player layer once frames are flowing.
    func playerDidStart() {
        reconnectTask?.cancel()
        reconnectTask = nil
        streamState = .playing
    }

    /// Called by the player layer when the connection drops or fails.
    func playerDidFail(_ message: String) {
        scheduleReconnect(reason: message)
    }

    private func handleFailure(_ message: String) {
        lastError = message
        streamState = .failed(message: message)
    }

    /// Exponential-backoff reconnect: 1, 2, 4, 8 … seconds, capped.
    private func scheduleReconnect(reason: String) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...self.maxReconnectAttempts {
                if Task.isCancelled { return }
                await MainActor.run { self.streamState = .reconnecting(attempt: attempt) }

                let delay = min(pow(2.0, Double(attempt - 1)), 30)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }

                // Rebuild the stream to force the player to retry. Reset to
                // `.idle` first so `start()`'s "already active" guard passes.
                await MainActor.run {
                    self.stream = nil
                    self.streamState = .idle
                    self.start()
                }
                return // start() will drive the next state transition
            }
            await MainActor.run { self.handleFailure("Failed to reconnect: \(reason)") }
        }
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
    }
}
