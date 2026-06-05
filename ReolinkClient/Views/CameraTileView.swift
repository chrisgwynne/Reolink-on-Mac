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

            if case .connecting = viewModel.streamState {
                ProgressView().controlSize(.large).tint(.white)
            }
            if case .reconnecting = viewModel.streamState {
                ProgressView().controlSize(.large).tint(.yellow)
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
            Button("Reconnect") { viewModel.stop(); viewModel.start() }
        }
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
            Button {
                Task { await snapshot() }
            } label: {
                Image(systemName: "camera.fill")
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.snapshotInProgress)
        }
    }

    private var statusBadge: some View {
        let color: Color
        switch viewModel.streamState {
        case .playing: color = .green
        case .connecting, .reconnecting: color = .yellow
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
