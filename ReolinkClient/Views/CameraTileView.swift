import SwiftUI

/// A single camera tile in the grid: live video plus a status/overlay bar and
/// quick snapshot action. Double-click opens the detail view.
struct CameraTileView: View {
    @StateObject private var viewModel: CameraViewModel
    let onOpenDetail: () -> Void

    @State private var snapshotConfirmation: String?

    init(camera: Camera, store: CameraStore, onOpenDetail: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CameraViewModel(camera: camera, store: store))
        self.onOpenDetail = onOpenDetail
    }

    var body: some View {
        ZStack {
            RTSPPlayerView(viewModel: viewModel)
                .background(Color.black)

            switch viewModel.streamState {
            case .connecting, .buffering:
                ProgressView().controlSize(.large).tint(.white)
            case .reconnecting, .stalled:
                ProgressView().controlSize(.large).tint(.yellow)
            case .failed(let message, let canRetry):
                errorOverlay(message: message, canRetry: canRetry)
            case .idle, .playing:
                EmptyView()
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpenDetail)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .contextMenu {
            Button("Open Large View", action: onOpenDetail)
            Button("Take Snapshot") { Task { await snapshot() } }
            Divider()
            Picker("Stream Quality", selection: qualityBinding) {
                ForEach(StreamQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
            Divider()
            if viewModel.streamState.isActive {
                Button("Stop Stream") { viewModel.stop() }
            } else {
                Button("Start Stream") { viewModel.start() }
            }
            Button("Refresh Stream") { viewModel.refresh() }
        }
    }

    /// Binding that drives the player to switch streams in place.
    private var qualityBinding: Binding<StreamQuality> {
        Binding(
            get: { viewModel.activeQuality },
            set: { viewModel.switchQuality(to: $0) }
        )
    }

    private var topBar: some View {
        HStack {
            Label(viewModel.camera.name, systemImage: "video.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
            Spacer()
            statusBadge
        }
    }

    private var bottomBar: some View {
        HStack {
            if let snapshotConfirmation {
                Text(snapshotConfirmation)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: Capsule())
                    .transition(.opacity)
            }
            Spacer()

            Menu {
                Picker("Stream Quality", selection: qualityBinding) {
                    ForEach(StreamQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
            } label: {
                Text(viewModel.activeQuality == .main ? "HD" : "SD")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            iconButton("arrow.clockwise") { viewModel.refresh() }

            iconButton("camera.fill") { Task { await snapshot() } }
                .disabled(viewModel.snapshotInProgress)
        }
    }

    /// Centered error panel with a Retry action.
    private func errorOverlay(message: String, canRetry: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
            if canRetry {
                Button {
                    viewModel.retry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .padding(20)
    }

    private func iconButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .padding(8)
                .background(.black.opacity(0.45), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        let color: Color
        switch viewModel.streamState {
        case .playing: color = .green
        case .connecting, .buffering: color = .yellow
        case .reconnecting, .stalled: color = .orange
        case .failed: color = .red
        case .idle: color = .gray
        }
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(viewModel.streamState.label)
                .font(.caption2)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func snapshot() async {
        guard let url = await viewModel.captureSnapshot() else {
            withAnimation { snapshotConfirmation = "Snapshot failed" }
            return
        }
        withAnimation { snapshotConfirmation = "Saved \(url.lastPathComponent)" }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { snapshotConfirmation = nil }
    }
}
