import Foundation

/// A motion / AI detection event reported by a Reolink camera.
struct CameraEvent: Identifiable, Hashable {
    let id: UUID
    let cameraID: UUID
    let kind: EventKind
    let startTime: Date
    let endTime: Date

    /// Whether the camera has recorded footage that can be played back for
    /// this event. Drives the "Playback not supported" fallback in the UI.
    let hasRecording: Bool

    /// The Reolink recording file reference (the `name` from a `Search`
    /// result), used to build the playback stream URL. Not a secret.
    let recordingName: String?

    init(
        id: UUID = UUID(),
        cameraID: UUID,
        kind: EventKind,
        startTime: Date,
        endTime: Date,
        hasRecording: Bool,
        recordingName: String? = nil
    ) {
        self.id = id
        self.cameraID = cameraID
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.hasRecording = hasRecording
        self.recordingName = recordingName
    }

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }
}

/// What a camera's player is currently showing.
enum PlaybackSource: Equatable {
    case live
    case recording(CameraEvent)
}

/// The classification reported for an event.
enum EventKind: String, Codable, CaseIterable, Identifiable {
    case motion
    case person
    case vehicle
    case animal
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .motion: return "Motion"
        case .person: return "Person"
        case .vehicle: return "Vehicle"
        case .animal: return "Animal"
        case .other: return "Event"
        }
    }

    /// SF Symbol used in the event list.
    var symbolName: String {
        switch self {
        case .motion: return "wave.3.right"
        case .person: return "figure.walk"
        case .vehicle: return "car.fill"
        case .animal: return "pawprint.fill"
        case .other: return "bell.fill"
        }
    }
}
