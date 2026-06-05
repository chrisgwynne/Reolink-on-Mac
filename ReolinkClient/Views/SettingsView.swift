import SwiftUI

/// Manage the configured cameras: add, edit, remove, and run network discovery.
struct SettingsView: View {
    @EnvironmentObject private var store: CameraStore

    @State private var editorRoute: EditorRoute?
    @State private var discovering = false
    @State private var discovered: [CameraDiscoveryService.DiscoveredCamera] = []

    private let discovery = CameraDiscoveryService()

    /// Drives the add/edit sheet via a single `.sheet(item:)`.
    private struct EditorRoute: Identifiable {
        let id = UUID()
        let camera: Camera?   // nil = add new
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                Section("Cameras") {
                    if store.cameras.isEmpty {
                        Text("No cameras configured.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.cameras) { camera in
                        cameraRow(camera)
                    }
                }

                if !discovered.isEmpty {
                    Section("Discovered on Network") {
                        ForEach(discovered) { device in
                            HStack {
                                Image(systemName: "wifi")
                                Text(device.address)
                                Spacer()
                                Button("Add") {
                                    prefillFromDiscovery(device)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    Task { await runDiscovery() }
                } label: {
                    if discovering {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Discover", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .disabled(discovering)

                Button {
                    store.addMockCamera()
                } label: {
                    Label("Add Mock", systemImage: "ladybug")
                }

                Spacer()

                Button {
                    editorRoute = EditorRoute(camera: nil)
                } label: {
                    Label("Add Camera", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 420)
        .sheet(item: $editorRoute) { route in
            AddCameraView(editing: route.camera)
                .environmentObject(store)
        }
    }

    private func cameraRow(_ camera: Camera) -> some View {
        HStack {
            Image(systemName: camera.isMock ? "ladybug.fill" : "video.fill")
                .foregroundStyle(camera.isMock ? .orange : .accentColor)
            VStack(alignment: .leading) {
                Text(camera.name).font(.body.weight(.medium))
                Text(camera.isMock ? "Mock camera" : "\(camera.host):\(camera.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if camera.capabilities.supportsPTZ {
                Image(systemName: "dpad").foregroundStyle(.secondary)
            }
            Button {
                editorRoute = EditorRoute(camera: camera)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                store.remove(camera)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func runDiscovery() async {
        discovering = true
        defer { discovering = false }
        discovered = await discovery.discover()
    }

    private func prefillFromDiscovery(_ device: CameraDiscoveryService.DiscoveredCamera) {
        editorRoute = EditorRoute(
            camera: Camera(
                name: "Camera \(device.address)",
                host: device.address,
                username: "admin"
            )
        )
    }
}

#Preview {
    SettingsView()
        .environmentObject(CameraStore())
}
