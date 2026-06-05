import Foundation
import Combine

/// Drives the "Sign in to your cameras" onboarding: one set of credentials,
/// a LAN scan, then a per-camera login attempt that auto-adds the ones that
/// authenticate. Discovery (``CameraDiscoveryService``) stays credential-free;
/// this view model orchestrates verification via ``ReolinkAPIClient``.
///
/// Credentials live only in memory here and in the Keychain (via
/// ``CameraStore``); they are never logged.
@MainActor
final class OnboardingViewModel: ObservableObject {

    /// Per-discovered-camera state shown live in the list.
    enum DeviceStatus: Equatable {
        case found
        case checking
        case added
        case duplicate
        case wrongCredentials
        case unreachable(String)

        var label: String {
            switch self {
            case .found: return "Found"
            case .checking: return "Checking login…"
            case .added: return "Added"
            case .duplicate: return "Already added"
            case .wrongCredentials: return "Wrong username or password"
            case .unreachable(let why): return why
            }
        }

        var isFailure: Bool {
            switch self {
            case .wrongCredentials, .unreachable: return true
            default: return false
            }
        }
    }

    /// One row in the discovery list.
    struct Row: Identifiable {
        let device: CameraDiscoveryService.DiscoveredCamera
        var status: DeviceStatus
        var id: String { device.host }
    }

    enum Phase: Equatable { case idle, scanning, finished }

    @Published var username = "admin"
    @Published var password = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [Row] = []

    private let store: CameraStore
    private let service: CameraDiscoveryService
    private let useMock: Bool
    private var scanTask: Task<Void, Never>?
    private var verifyTasks: [Task<Void, Never>] = []

    init(store: CameraStore,
         service: CameraDiscoveryService = CameraDiscoveryService(),
         useMock: Bool = false) {
        self.store = store
        self.service = service
        self.useMock = useMock
    }

    // MARK: - Derived UI state

    var canScan: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var addedCount: Int { rows.filter { $0.status == .added }.count }

    var statusText: String {
        switch phase {
        case .idle:
            return "Enter your camera credentials, then scan."
        case .scanning:
            return rows.isEmpty
                ? "Scanning local network…"
                : "Scanning… found \(rows.count) so far"
        case .finished:
            if rows.isEmpty { return "No cameras found. Try manual add." }
            return "Found \(rows.count) — added \(addedCount)."
        }
    }

    // MARK: - Scan

    func scan() {
        cancel()
        rows = []
        phase = .scanning

        scanTask = Task { [weak self] in
            guard let self else { return }
            if self.useMock {
                for device in CameraDiscoveryService.mockResults {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    self.handleDiscovered(device)
                }
            } else {
                for await device in self.service.discover(timeout: 6) {
                    if Task.isCancelled { return }
                    self.handleDiscovered(device)
                }
            }
            if !Task.isCancelled { self.phase = .finished }
        }
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        verifyTasks.forEach { $0.cancel() }
        verifyTasks = []
    }

    /// Re-attempt login for a previously failed camera (e.g. after correcting
    /// the master password).
    func retry(_ row: Row) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[index].status = .checking
        let device = row.device
        verifyTasks.append(Task { [weak self] in
            await self?.verifyAndAdd(device)
        })
    }

    // MARK: - Per-device handling

    private func handleDiscovered(_ device: CameraDiscoveryService.DiscoveredCamera) {
        // Dedupe within the current scan.
        guard !rows.contains(where: { $0.id == device.host }) else { return }

        // Dedupe against already-configured cameras (by host/IP).
        if store.cameras.contains(where: { $0.host == device.host }) {
            rows.append(Row(device: device, status: .duplicate))
            return
        }

        rows.append(Row(device: device, status: useMock ? .checking : .found))
        verifyTasks.append(Task { [weak self] in
            await self?.verifyAndAdd(device)
        })
    }

    /// Attempt a Reolink login with the master credentials; on success, persist
    /// the camera (password → Keychain) and add it to the grid.
    private func verifyAndAdd(_ device: CameraDiscoveryService.DiscoveredCamera) async {
        setStatus(.checking, for: device.host)

        // Mock onboarding: simulate a successful add without a real network call.
        if useMock {
            let camera = makeCamera(for: device)
            try? store.add(camera, password: password)
            setStatus(.added, for: device.host)
            return
        }

        let candidate = makeCamera(for: device)
        let api = ReolinkAPIClient(camera: candidate)
        do {
            try await api.login(password: password)
            let capabilities = (try? await api.fetchCapabilities()) ?? CameraCapabilities()
            var camera = candidate
            camera.capabilities = capabilities

            // Re-check for duplicates in case it was added concurrently.
            guard !store.cameras.contains(where: { $0.host == device.host }) else {
                setStatus(.duplicate, for: device.host)
                return
            }
            try store.add(camera, password: password)
            setStatus(.added, for: device.host)
        } catch let error as ReolinkAPIClient.APIError {
            switch error {
            case .apiFailure, .notLoggedIn:
                setStatus(.wrongCredentials, for: device.host)
            default:
                setStatus(.unreachable(error.localizedDescription), for: device.host)
            }
        } catch {
            setStatus(.unreachable(error.localizedDescription), for: device.host)
        }
    }

    private func makeCamera(for device: CameraDiscoveryService.DiscoveredCamera) -> Camera {
        Camera(
            name: device.suggestedName,
            host: device.host,
            port: 80,
            rtspPort: 554,
            username: username
        )
    }

    private func setStatus(_ status: DeviceStatus, for host: String) {
        guard let index = rows.firstIndex(where: { $0.id == host }) else { return }
        rows[index].status = status
    }

    deinit {
        scanTask?.cancel()
        verifyTasks.forEach { $0.cancel() }
    }
}
