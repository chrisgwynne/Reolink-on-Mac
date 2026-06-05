import SwiftUI

/// Directional PTZ pad plus zoom controls. Hidden by the parent when the camera
/// does not support PTZ. Press-and-hold drives the camera; release sends Stop.
struct PTZControlView: View {
    @ObservedObject var viewModel: CameraViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Pan / Tilt")
                .font(.headline)

            directionalPad

            if viewModel.camera.capabilities.supportsZoom {
                Divider()
                zoomControls
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var directionalPad: some View {
        VStack(spacing: 8) {
            ptzButton(.up, system: "chevron.up")
            HStack(spacing: 8) {
                ptzButton(.left, system: "chevron.left")
                Button {
                    Task { await viewModel.ptz(.stop) }
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                ptzButton(.right, system: "chevron.right")
            }
            ptzButton(.down, system: "chevron.down")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 24) {
            Label("Zoom", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
            Spacer()
            ptzButton(.zoomOut, system: "minus.magnifyingglass")
            ptzButton(.zoomIn, system: "plus.magnifyingglass")
        }
    }

    /// A button that starts the operation on press and sends Stop on release.
    private func ptzButton(_ op: PTZOperation, system: String) -> some View {
        Image(systemName: system)
            .frame(width: 44, height: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        Task { await viewModel.ptz(op) }
                    }
                    .onEnded { _ in
                        Task { await viewModel.ptz(.stop) }
                    }
            )
            .accessibilityLabel(Text(op.rawValue))
    }
}
