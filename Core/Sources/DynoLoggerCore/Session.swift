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
    /// Open-Meteo snapshots taken at the start and end of the run (empty when the phone had no signal or the person
    /// turned weather off).
    public var weather: [WeatherSnapshot]
    /// Whether the iPhone's barometer was recorded.
    public var phoneBarometer: Bool
    /// The vehicle profile typed in the app for this vehicle, as it was when the run was recorded.
    public var vehicleProfile: VehicleProfile?
    /// The Accessport log attached to this run, if any.
    public var accessport: AttachedLog?

    public struct AttachedLog: Codable, Equatable, Sendable {
        public var file: String
        public var offset: TimeInterval
        public var method: AccessportMerge.Method
        public var matchError: Double?
        public init(file: String, offset: TimeInterval, method: AccessportMerge.Method, matchError: Double?) {
            self.file = file
            self.offset = offset
            self.method = method
            self.matchError = matchError
        }
    }

    public init(vehicle: String, start: Date, end: Date, engineRows: Int, trackPoints: Int, trackSource: String?,
                obdAdapter: String?, pedalSource: PedalSource?, goProRecorded: Bool,
                weather: [WeatherSnapshot] = [], phoneBarometer: Bool = false, vehicleProfile: VehicleProfile? = nil) {
        self.vehicle = vehicle
        self.start = start
        self.end = end
        self.engineRows = engineRows
        self.trackPoints = trackPoints
        self.trackSource = trackSource
        self.obdAdapter = obdAdapter
        self.pedalSource = pedalSource
        self.goProRecorded = goProRecorded
        self.weather = weather
        self.phoneBarometer = phoneBarometer
        self.vehicleProfile = vehicleProfile
    }

    // session.json files written by 1.0 have neither key.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vehicle = try c.decode(String.self, forKey: .vehicle)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        engineRows = try c.decode(Int.self, forKey: .engineRows)
        trackPoints = try c.decode(Int.self, forKey: .trackPoints)
        trackSource = try c.decodeIfPresent(String.self, forKey: .trackSource)
        obdAdapter = try c.decodeIfPresent(String.self, forKey: .obdAdapter)
        pedalSource = try c.decodeIfPresent(PedalSource.self, forKey: .pedalSource)
        goProRecorded = try c.decode(Bool.self, forKey: .goProRecorded)
        weather = try c.decodeIfPresent([WeatherSnapshot].self, forKey: .weather) ?? []
        phoneBarometer = try c.decodeIfPresent(Bool.self, forKey: .phoneBarometer) ?? false
        vehicleProfile = try c.decodeIfPresent(VehicleProfile.self, forKey: .vehicleProfile)
        accessport = try c.decodeIfPresent(AttachedLog.self, forKey: .accessport)
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
            try EngineLog.csv(engine, pedalSource: summary.pedalSource ?? .pedal, weather: summary.weather, start: summary.start,
                              vehicle: summary.vehicleProfile)
                .write(to: dir.appendingPathComponent(name + ".csv"), atomically: true, encoding: .utf8)
        }
        if !track.isEmpty {
            try GPX.document(track, name: name)
                .write(to: dir.appendingPathComponent(name + ".gpx"), atomically: true, encoding: .utf8)
        }
        try writeSummary(summary, to: dir)
        return dir
    }

    public static func writeSummary(_ summary: SessionSummary, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(summary).write(to: dir.appendingPathComponent("session.json"))
    }

    /// Attaches an Accessport log to a saved run. The run's own OBD-II log moves to `sources/<name>_obd.csv` and the
    /// Accessport's file is kept beside it as it was; the merged log takes the run's `<name>.csv`, which is the file
    /// for the dyno. Attaching again starts from the kept OBD-II log, so it never merges a merge.
    @discardableResult
    public static func attachAccessport(_ text: String, fileName: String, to dir: URL) throws -> AccessportMerge.Result {
        let fm = FileManager.default
        let name = dir.lastPathComponent
        let src = dir.appendingPathComponent("sources", isDirectory: true)
        let kept = src.appendingPathComponent(name + "_obd.csv"), live = dir.appendingPathComponent(name + ".csv")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var summary = try? dec.decode(SessionSummary.self, from: Data(contentsOf: dir.appendingPathComponent("session.json")))
        var obd: String?
        if fm.fileExists(atPath: kept.path) { obd = try String(contentsOf: kept, encoding: .utf8) }
        else if fm.fileExists(atPath: live.path) { obd = try String(contentsOf: live, encoding: .utf8) }
        var track: [(time: TimeInterval, speed: Double)] = []
        if let s = summary, let g = try? String(contentsOf: dir.appendingPathComponent(name + ".gpx"), encoding: .utf8) {
            track = GPX.speeds(g, start: s.start)
        }
        let r = try AccessportMerge.merge(accessport: text, obdLog: obd, track: track, summary: summary)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: kept.path), fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: kept) }
        let safe = fileName.replacingOccurrences(of: "/", with: "_")
        try text.write(to: src.appendingPathComponent("accessport_" + safe), atomically: true, encoding: .utf8)
        try r.csv.write(to: live, atomically: true, encoding: .utf8)
        if summary != nil {
            summary!.accessport = SessionSummary.AttachedLog(file: safe, offset: r.offset, method: r.method, matchError: r.matchError)
            try writeSummary(summary!, to: dir)
        }
        return r
    }

    /// Takes the Accessport log off a run: the run's own OBD-II log goes back to `<name>.csv`.
    public static func detachAccessport(from dir: URL) throws {
        let fm = FileManager.default, name = dir.lastPathComponent
        let src = dir.appendingPathComponent("sources", isDirectory: true)
        let kept = src.appendingPathComponent(name + "_obd.csv"), live = dir.appendingPathComponent(name + ".csv")
        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
        if fm.fileExists(atPath: kept.path) { try fm.moveItem(at: kept, to: live) }
        try? fm.removeItem(at: src)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if var s = try? dec.decode(SessionSummary.self, from: Data(contentsOf: dir.appendingPathComponent("session.json"))) {
            s.accessport = nil
            try writeSummary(s, to: dir)
        }
    }
}
