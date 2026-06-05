import SwiftUI

/// Lists detection events for a camera on a selected date, and offers playback
/// when the camera/model supports it.
struct EventListView: View {
    @ObservedObject var viewModel: CameraViewModel

    @State private var selectedDate = Date()
    @State private var selectedEvent: CameraEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                Button {
                    Task { await viewModel.loadEvents(on: selectedDate) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                if viewModel.loadingEvents {
                    ProgressView().controlSize(.small)
                }
            }

            if !viewModel.camera.capabilities.supportsEvents {
                ContentUnavailableMessage(
                    title: "Events not supported",
                    detail: "This camera model does not report detection events.",
                    systemImage: "bell.slash"
                )
            } else if viewModel.events.isEmpty && !viewModel.loadingEvents {
                ContentUnavailableMessage(
                    title: "No events",
                    detail: "No detections were found for the selected date.",
                    systemImage: "calendar.badge.exclamationmark"
                )
            } else {
                List {
                    ForEach(viewModel.events) { event in
                        EventRow(event: event)
                            .contentShape(Rectangle())
                            .listRowBackground(
                                selectedEvent == event
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.clear
                            )
                            .onTapGesture { selectedEvent = event }
                    }
                }
                .listStyle(.inset)
            }

            if let selectedEvent {
                playbackPanel(for: selectedEvent)
            }
        }
        .padding()
        .onChange(of: selectedDate) { _, newValue in
            Task { await viewModel.loadEvents(on: newValue) }
        }
        .task {
            await viewModel.loadEvents(on: selectedDate)
        }
    }

    @ViewBuilder
    private func playbackPanel(for event: CameraEvent) -> some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback")
                .font(.headline)
            if viewModel.camera.capabilities.supportsPlayback && event.hasRecording {
                Label(
                    "\(event.kind.displayName) • \(event.startTime.formatted(date: .omitted, time: .standard))",
                    systemImage: "play.rectangle.fill"
                )
                Text("Playback streams the recorded clip over RTSP from the camera's SD card.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    // Hook for real playback: build a playback RTSP/HTTP URL and
                    // hand it to the player. Left as an integration point.
                } label: {
                    Label("Play Clip", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label("Playback not supported for this model", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EventRow: View {
    let event: CameraEvent

    var body: some View {
        HStack {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text(event.kind.displayName)
                    .font(.body.weight(.medium))
                Text(event.startTime.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(event.duration))s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if event.hasRecording {
                Image(systemName: "recordingtape")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Small reusable "nothing here" panel (avoids relying on a specific macOS SDK).
struct ContentUnavailableMessage: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
