import Foundation
import AppKit

/// Generates synthetic media for the mock camera mode so the app can be
/// developed and demoed without real hardware.
enum MockMedia {

    /// Render a labelled placeholder snapshot as JPEG data.
    static func snapshotJPEG(label: String) -> Data {
        let size = NSSize(width: 1280, height: 720)
        let image = NSImage(size: size)
        image.lockFocus()

        // Gradient background.
        let gradient = NSGradient(
            colors: [
                NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.18, alpha: 1),
                NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.32, alpha: 1)
            ]
        )
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 90)

        // Centered label.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph
        ]
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let text = "\(label)\n\(timestamp)" as NSString
        let rect = NSRect(x: 0, y: size.height / 2 - 80, width: size.width, height: 160)
        text.draw(in: rect, withAttributes: attributes)

        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else {
            return Data()
        }
        return jpeg
    }

    /// Deterministic sample events for a mock camera on a given day.
    static func events(for cameraID: UUID, on day: Date) -> [CameraEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let kinds: [(EventKind, Int)] = [
            (.person, 8), (.vehicle, 9), (.motion, 12), (.animal, 15), (.person, 18)
        ]
        return kinds.enumerated().map { index, item in
            let begin = calendar.date(byAdding: .hour, value: item.1, to: start) ?? start
            let end = begin.addingTimeInterval(Double(20 + index * 5))
            return CameraEvent(
                cameraID: cameraID,
                kind: item.0,
                startTime: begin,
                endTime: end,
                hasRecording: index % 2 == 0
            )
        }
    }
}
