import Foundation

/// What one recording leaves on disk: a folder per run holding the engine log, the GPS track and a summary.
///
///     GolfR_2026-10-10_170503/
///       GolfR_2026-10-10_170503.csv   -> Virtual Dyno "Cobb Accessport log" box
///       GolfR_2026-10-10_170503.gpx   -> Virtual Dyno "RaceBox, Dragy or GPX" box (and video-overlay)
///       session.json                  -> start time, devices, GoPro state
///
/// The dyno names its Print image after the log ("<name>_VirtualDyno.jpg"), so the vehicle name leads.
public struct SessionSummary: Codable, Equatable, Sendable {
    public var vehicle: String
    public var start: Date
    public var end: Date
    public var engineRows: Int
    public var trackPoints: Int
    public var trackSource: String?
    public var obdAdapter: String?
    public var pedalSource: PedalSource?
    public var goProRecorded: Bool

    public init(vehicle: String, start: Date, end: Date, engineRows: Int, trackPoints: Int, trackSource: String?,
                obdAdapter: String?, pedalSource: PedalSource?, goProRecorded: Bool) {
        self.vehicle = vehicle
        self.start = start
        self.end = end
        self.engineRows = engineRows
        self.trackPoints = trackPoints
        self.trackSource = trackSource
        self.obdAdapter = obdAdapter
        self.pedalSource = pedalSource
        self.goProRecorded = goProRecorded
    }
}

public enum SessionFiles {
    /// "Golf R" at 2026-10-10 17:05:03 local -> "GolfR_2026-10-10_170503".
    public static func baseName(vehicle: String, start: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let v = vehicle.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return (v.isEmpty ? "Run" : v) + "_" + f.string(from: start)
    }

    /// Writes the session folder under `root` and returns it. Files with no data are left out.
    @discardableResult
    public static func write(to root: URL, summary: SessionSummary, engine: [EngineSample], track: [TrackPoint]) throws -> URL {
        let name = baseName(vehicle: summary.vehicle, start: summary.start)
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !engine.isEmpty {
            try EngineLog.csv(engine, pedalSource: summary.pedalSource ?? .pedal)
                .write(to: dir.appendingPathComponent(name + ".csv"), atomically: true, encoding: .utf8)
        }
        if !track.isEmpty {
            try GPX.document(track, name: name)
                .write(to: dir.appendingPathComponent(name + ".gpx"), atomically: true, encoding: .utf8)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(summary).write(to: dir.appendingPathComponent("session.json"))
        return dir
    }
}
