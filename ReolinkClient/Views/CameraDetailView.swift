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

                if case .recording = viewModel.source {
                    // Viewing a recorded clip — offer a clear way back to live.
                    Label("Recorded clip", systemImage: "play.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { viewModel.returnToLive() } label: {
                        Label("Back to Live", systemImage: "dot.radiowaves.left.and.right")
                    }
                } else {
                    Picker("Quality", selection: qualityBinding) {
                        ForEach(StreamQuality.allCases) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if viewModel.streamState.isActive {
                        Button { viewModel.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button { viewModel.start() } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                    }
                    Button { viewModel.refresh() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
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

    /// Binding that drives in-place stream switching from the toolbar.
    private var qualityBinding: Binding<StreamQuality> {
        Binding(
            get: { viewModel.activeQuality },
            set: { viewModel.switchQuality(to: $0) }
        )
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RTSPPlayerView(viewModel: viewModel)
                    .background(Color.black)

                centerOverlay

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

    /// Loading spinner or error+Retry panel centered over the video.
    @ViewBuilder
    private var centerOverlay: some View {
        switch viewModel.streamState {
        case .connecting, .buffering:
            ProgressView(viewModel.streamState.label)
                .controlSize(.large).tint(.white)
                .padding()
        case .reconnecting, .stalled:
            ProgressView(viewModel.streamState.label)
                .controlSize(.large).tint(.yellow)
                .padding()
        case .failed(let message, let canRetry):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                if canRetry {
                    Button { viewModel.retry() } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        case .idle, .playing:
            EmptyView()
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
