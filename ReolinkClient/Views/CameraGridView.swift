import SwiftUI

/// Grid of camera tiles with selectable 1×1, 2×2, 3×3, and 4×4 layouts.
struct CameraGridView: View {
    @EnvironmentObject private var store: CameraStore
    @Binding var layout: GridLayout
    @Binding var selectedCamera: Camera?

    var body: some View {
        GeometryReader { geo in
            if store.cameras.isEmpty {
                emptyState
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                let spacing: CGFloat = 8
                let columns = Array(
                    repeating: GridItem(.flexible(), spacing: spacing),
                    count: layout.columns
                )
                ScrollView {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(displayCameras) { camera in
                            CameraTileView(camera: camera, store: store) {
                                selectedCamera = camera
                            }
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        }
                    }
                    .padding(spacing)
                }
            }
        }
    }

    /// Cameras shown for the current layout (cap at the grid capacity).
    private var displayCameras: [Camera] {
        Array(store.cameras.prefix(layout.capacity))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No cameras yet")
                .font(.title3.weight(.semibold))
            Text("Add a Reolink camera or create a mock camera to get started.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Mock Camera") { store.addMockCamera() }
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
    }
}

/// Supported grid layouts.
enum GridLayout: String, CaseIterable, Identifiable {
    case single = "1×1"
    case twoByTwo = "2×2"
    case threeByThree = "3×3"
    case fourByFour = "4×4"

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .single: return 1
        case .twoByTwo: return 2
        case .threeByThree: return 3
        case .fourByFour: return 4
        }
    }

    var capacity: Int { columns * columns }

    var symbolName: String {
        switch self {
        case .single: return "square"
        case .twoByTwo: return "square.grid.2x2"
        case .threeByThree: return "square.grid.3x3"
        case .fourByFour: return "square.grid.4x3.fill"
        }
    }
}
