import SwiftUI

/// Manage the configured cameras: add (via onboarding scan or manual), edit,
/// and remove. The "Scan LAN" entry point reuses the onboarding flow.
struct SettingsView: View {
    @EnvironmentObject private var store: CameraStore

    @State private var editorRoute: EditorRoute?
    @State private var showingOnboarding = false

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
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Button {
                    showingOnboarding = true
                } label: {
                    Label("Scan LAN", systemImage: "antenna.radiowaves.left.and.right")
                }

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
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(store: store)
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
}

#Preview {
    SettingsView()
        .environmentObject(CameraStore())
}
