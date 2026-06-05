import Foundation
import Combine

/// App-wide store of configured cameras.
///
/// Persists the non-secret camera metadata to `UserDefaults` (as JSON) and
/// delegates password storage to ``KeychainService``. Marked `@MainActor` so
/// SwiftUI views observe it safely.
@MainActor
final class CameraStore: ObservableObject {
    @Published private(set) var cameras: [Camera] = []

    private let keychain: KeychainService
    private let defaults: UserDefaults
    private let storageKey = "com.reolinkonmac.cameras"

    init(keychain: KeychainService = KeychainService(), defaults: UserDefaults = .standard) {
        self.keychain = keychain
        self.defaults = defaults
        load()
    }

    // MARK: - CRUD

    /// Add a new camera, persisting its password to the Keychain.
    func add(_ camera: Camera, password: String) throws {
        if !camera.isMock {
            try keychain.setPassword(password, for: camera.id)
        }
        cameras.append(camera)
        persist()
    }

    /// Update an existing camera. Pass a new password to rotate it.
    func update(_ camera: Camera, password: String? = nil) throws {
        if let password, !camera.isMock {
            try keychain.setPassword(password, for: camera.id)
        }
        if let index = cameras.firstIndex(where: { $0.id == camera.id }) {
            cameras[index] = camera
        } else {
            cameras.append(camera)
        }
        persist()
    }

    /// Remove a camera and its stored password.
    func remove(_ camera: Camera) {
        cameras.removeAll { $0.id == camera.id }
        try? keychain.deletePassword(for: camera.id)
        persist()
    }

    /// Look up the stored password for a camera.
    func password(for camera: Camera) throws -> String? {
        if camera.isMock { return "mock" }
        return try keychain.password(for: camera.id)
    }

    /// Add a ready-made mock camera for development.
    func addMockCamera() {
        let mock = Camera.mock(name: "Mock Camera \(cameras.filter(\.isMock).count + 1)")
        cameras.append(mock)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(cameras)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Persistence failures are non-fatal; the in-memory list still works.
            assertionFailure("Failed to persist cameras: \(error)")
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            cameras = try JSONDecoder().decode([Camera].self, from: data)
        } catch {
            cameras = []
        }
    }
}
