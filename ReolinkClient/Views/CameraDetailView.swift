import SwiftUI

/// Large single-camera view opened by double-clicking a tile. Hosts the live
/// stream, a PTZ panel (when supported), snapshots, and an events sidebar.
struct CameraDetailView: View {
    @EnvironmentObject private var store: CameraStore
    @StateObject private var viewModel: CameraViewModel

    @State private var showEvents = false
    @State private var statusMessage: String?

    init(camera: Camera, store: CameraStore) {
        _viewModel = StateObject(wrappedValue: CameraViewModel(camera: camera, store: store))
    }

    var body: some View {
        HSplitView {
            mainColumn
                .frame(minWidth: 480)

            if showEvents {
                EventListView(viewModel: viewModel)
                    .frame(minWidth: 280, idealWidth: 340)
            }
        }
        .navigationTitle(viewModel.camera.name)
        .toolbar {
            ToolbarItemGroup {
                if let info = viewModel.deviceInfo {
                    Text(info.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await snapshot() }
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }
                Toggle(isOn: $showEvents) {
                    Label("Events", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .onAppear {
            viewModel.start(quality: .main)
            Task { await viewModel.refreshDeviceInfo() }
        }
        .onDisappear { viewModel.stop() }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RTSPPlayerView(viewModel: viewModel)
                    .background(Color.black)

                if case .connecting = viewModel.streamState {
                    ProgressView().controlSize(.large).tint(.white).padding()
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }

            if viewModel.camera.capabilities.supportsPTZ {
                PTZControlView(viewModel: viewModel)
                    .padding()
            }
        }
    }

    private func snapshot() async {
        guard let url = await viewModel.captureSnapshot() else {
            await flash("Snapshot failed")
            return
        }
        await flash("Saved \(url.lastPathComponent)")
    }

    private func flash(_ message: String) async {
        withAnimation { statusMessage = message }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { statusMessage = nil }
    }
}
