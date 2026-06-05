import Foundation

/// Saves snapshots to `~/Pictures/Reolink Snapshots` with the required
/// `camera-name_yyyy-MM-dd_HH-mm-ss.jpg` filename format.
enum SnapshotStore {

    enum SnapshotError: LocalizedError {
        case noPicturesDirectory

        var errorDescription: String? {
            switch self {
            case .noPicturesDirectory:
                return "Could not locate the Pictures directory."
            }
        }
    }

    /// Directory where snapshots are written, created on demand.
    static func directory() throws -> URL {
        guard let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            throw SnapshotError.noPicturesDirectory
        }
        let dir = pictures.appendingPathComponent("Reolink Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Persist JPEG `data` and return the file URL.
    @discardableResult
    static func save(_ data: Data, cameraName: String, date: Date = Date()) throws -> URL {
        let dir = try directory()
        let filename = "\(sanitize(cameraName))_\(timestamp(date)).jpg"
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    private static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Strip path-hostile characters from the camera name for the filename.
    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>| ")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "camera" : cleaned
    }
}
