import SwiftUI

/// "Sign in to your cameras" onboarding: enter credentials once, scan the LAN,
/// and auto-add every camera that authenticates. Failed cameras stay visible
/// with Retry / Add Manually. Falls back to the unchanged manual flow.
struct OnboardingView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: OnboardingViewModel

    /// Drives the manual Add Camera sheet (optionally prefilled from a device).
    @State private var manualRoute: ManualRoute?

    private struct ManualRoute: Identifiable {
        let id = UUID()
        let camera: Camera?
    }

    init(store: CameraStore, useMock: Bool = false) {
        _vm = StateObject(wrappedValue: OnboardingViewModel(store: store, useMock: useMock))
    }

    var body: some View {
        VStack(spacing: 0) {
            credentials
            Divider()
            results
            Divider()
            footer
        }
        .frame(width: 520, height: 580)
        .sheet(item: $manualRoute) { route in
            AddCameraView(editing: route.camera)
                .environmentObject(store)
        }
    }

    // MARK: - Credentials

    private var credentials: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "video.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Sign in to your cameras")
                        .font(.title2.weight(.semibold))
                    Text("Use your Reolink username and password to find and add cameras on this network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Username").gridColumnAlignment(.trailing)
                    TextField("admin", text: $vm.username)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password").gridColumnAlignment(.trailing)
                    SecureField("Password", text: $vm.password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if vm.canScan { vm.scan() } }
                }
            }

            HStack {
                Button {
                    vm.scan()
                } label: {
                    if vm.phase == .scanning {
                        Label("Scanning…", systemImage: "antenna.radiowaves.left.and.right")
                    } else {
                        Label("Scan for cameras", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canScan || vm.phase == .scanning)

                Button("Add manually") {
                    manualRoute = ManualRoute(camera: nil)
                }

                Spacer()

                if vm.phase == .scanning {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding()
    }

    // MARK: - Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)

            if vm.rows.isEmpty {
                emptyState
            } else {
                List(vm.rows) { row in
                    DiscoveryRowView(
                        row: row,
                        onRetry: { vm.retry(row) },
                        onManual: { manualRoute = ManualRoute(camera: prefilledCamera(for: row.device)) }
                    )
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: vm.phase == .scanning ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(vm.phase == .finished ? "No cameras found" : "Looking for cameras…")
                .font(.headline)
            if vm.phase == .finished {
                Text("They may be on another subnet, have ONVIF disabled, or block multicast.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Add manually") { manualRoute = ManualRoute(camera: nil) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if vm.addedCount > 0 {
                Label("\(vm.addedCount) added", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Spacer()
            Button("Done") {
                vm.cancel()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    /// Prefill a manual Add Camera with the discovered host + master username
    /// (password intentionally left blank for the user to enter per-camera).
    private func prefilledCamera(for device: CameraDiscoveryService.DiscoveredCamera) -> Camera {
        Camera(
            name: device.suggestedName,
            host: device.host,
            username: vm.username
        )
    }
}

/// One discovered-camera row with live status and recovery actions.
private struct DiscoveryRowView: View {
    let row: OnboardingViewModel.Row
    let onRetry: () -> Void
    let onManual: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.device.displayName)
                        .font(.body.weight(.medium))
                    if row.device.isLikelyReolink {
                        Text("Reolink")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
                Text("\(row.device.host) • \(row.status.label)")
                    .font(.caption)
                    .foregroundStyle(row.status.isFailure ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if row.status.isFailure {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
                Button("Add Manually", action: onManual)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .found:
            Image(systemName: "wifi").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small)
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .duplicate:
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .wrongCredentials:
            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
        case .unreachable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

#Preview {
    OnboardingView(store: CameraStore(), useMock: true)
        .environmentObject(CameraStore())
}
