import SwiftUI

/// Form for adding (or editing) a camera, with a "Test Connection" action that
/// validates credentials against the device before saving.
struct AddCameraView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    /// When non-nil, the form edits an existing camera.
    var editing: Camera? = nil

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "80"
    @State private var rtspPort: String = "554"
    @State private var username: String = "admin"
    @State private var password: String = ""
    @State private var useHTTPS = false
    @State private var preferredStream: StreamQuality = .sub

    @State private var testState: TestState = .idle
    @State private var saveError: String?

    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Camera") {
                    TextField("Name", text: $name, prompt: Text("Front Door"))
                    TextField("IP address or host", text: $host, prompt: Text("192.168.1.20"))
                }

                Section("Connection") {
                    HStack {
                        TextField("HTTP port", text: $port)
                            .frame(maxWidth: 120)
                        Spacer()
                        Toggle("Use HTTPS", isOn: $useHTTPS)
                    }
                    TextField("RTSP port", text: $rtspPort)
                        .frame(maxWidth: 120)
                    Picker("Default stream", selection: $preferredStream) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                }

                Section("Credentials") {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                }

                Section {
                    HStack(spacing: 12) {
                        Button {
                            Task { await testConnection() }
                        } label: {
                            if testState == .testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Test Connection", systemImage: "bolt.horizontal.circle")
                            }
                        }
                        .disabled(!isValid || testState == .testing)

                        testStatusView
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add Camera" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 460, height: 560)
        .navigationTitle(editing == nil ? "Add Camera" : "Edit Camera")
        .onAppear(perform: populateForEditing)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.isEmpty &&
        Int(port) != nil &&
        Int(rtspPort) != nil
    }

    private func makeCamera(capabilities: CameraCapabilities? = nil) -> Camera {
        Camera(
            id: editing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 80,
            rtspPort: Int(rtspPort) ?? 554,
            username: username,
            useHTTPS: useHTTPS,
            preferredStream: preferredStream,
            isMock: editing?.isMock ?? false,
            capabilities: capabilities ?? editing?.capabilities ?? CameraCapabilities()
        )
    }

    private func testConnection() async {
        testState = .testing
        let candidate = makeCamera()
        let api = ReolinkAPIClient(camera: candidate)
        do {
            let info = try await api.testConnection(password: password)
            testState = .success("Connected to \(info.model)")
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }

    private func save() {
        Task {
            // Best-effort capability discovery so PTZ/playback show correctly.
            var capabilities: CameraCapabilities?
            let candidate = makeCamera()
            if !candidate.isMock {
                let api = ReolinkAPIClient(camera: candidate)
                do {
                    try await api.login(password: password)
                    capabilities = try? await api.fetchCapabilities()
                } catch {
                    // Saving is still allowed even if discovery fails.
                }
            }

            let camera = makeCamera(capabilities: capabilities)
            do {
                if editing == nil {
                    try store.add(camera, password: password)
                } else {
                    try store.update(camera, password: password.isEmpty ? nil : password)
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func populateForEditing() {
        guard let editing else { return }
        name = editing.name
        host = editing.host
        port = String(editing.port)
        rtspPort = String(editing.rtspPort)
        username = editing.username
        useHTTPS = editing.useHTTPS
        preferredStream = editing.preferredStream
        // Password is intentionally not prefilled from the Keychain.
    }
}

#Preview {
    AddCameraView()
        .environmentObject(CameraStore())
}
