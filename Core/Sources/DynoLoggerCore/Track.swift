import Foundation

/// One GPS fix, from the phone, a RaceBox or an NMEA receiver.
public struct TrackPoint: Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// Metres above mean sea level.
    public var altitude: Double?
    /// Metres per second.
    public var speed: Double?
    /// Degrees from true north.
    public var course: Double?
    public var satellites: Int?
    public var hdop: Double?
    /// The iPhone's barometric altitude change since the run started (CMAltimeter), metres. GPS elevation wanders by
    /// metres; this moves in steps of about 10 cm, so it gives a much cleaner road grade over a pull or a coast.
    public var relativeAltitude: Double?
    /// The iPhone's barometer, hPa.
    public var pressure: Double?

    public init(time: Date, latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil,
                course: Double? = nil, satellites: Int? = nil, hdop: Double? = nil,
                relativeAltitude: Double? = nil, pressure: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.satellites = satellites
        self.hdop = hdop
        self.relativeAltitude = relativeAltitude
        self.pressure = pressure
    }
}

/// Writes the track as GPX 1.0, which the Virtual Dyno's "RaceBox, Dragy or GPX" box parses (`parseGPS()`), and so
/// does video-overlay (`parseGpx`). GPX 1.0 rather than 1.1 because 1.0 allows `<speed>` (m/s) and `<course>` inside a
/// `<trkpt>`, and both readers look for a plain `<speed>` tag: the dyno uses that GPS speed directly when the track is
/// 5 Hz or faster, and works speed out from positions otherwise. Each point needs a time; the dyno also uses `<ele>`
/// for road grade and density altitude, and lat/lon for heading and the weather lookup.
///
/// The iPhone's barometer goes in two extra elements in the app's own namespace, which GPX 1.0 allows anywhere and
/// other readers skip: `<dl:relalt>` (metres since the run started, for road grade) and `<dl:pressure>` (hPa).
public enum GPX {
    public static let namespace = "https://dynologger.turboloser.co/gpx/1"

    public static func document(_ points: [TrackPoint], name: String, creator: String = "Virtual Dyno Logger") -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.0" creator="\(escape(creator))" xmlns="http://www.topografix.com/GPX/1/0" xmlns:dl="\(namespace)">
        <trk><name>\(escape(name))</name><trkseg>

        """
        var last: Date?
        for p in points where p.latitude.isFinite && p.longitude.isFinite {
            if let l = last, p.time <= l { continue }
            last = p.time
            out += "<trkpt lat=\"\(fmt(p.latitude, 7))\" lon=\"\(fmt(p.longitude, 7))\">"
            if let a = p.altitude, a.isFinite { out += "<ele>\(fmt(a, 2))</ele>" }
            out += "<time>\(timestamp(p.time))</time>"
            if let c = p.course, c.isFinite, c >= 0 { out += "<course>\(fmt(c, 1))</course>" }
            if let s = p.speed, s.isFinite, s >= 0 { out += "<speed>\(fmt(s, 3))</speed>" }
            if let n = p.satellites { out += "<sat>\(n)</sat>" }
            if let h = p.hdop, h.isFinite { out += "<hdop>\(fmt(h, 2))</hdop>" }
            if let r = p.relativeAltitude, r.isFinite { out += "<dl:relalt>\(fmt(r, 2))</dl:relalt>" }
            if let b = p.pressure, b.isFinite { out += "<dl:pressure>\(fmt(b, 2))</dl:pressure>" }
            out += "</trkpt>\n"
        }
        out += "</trkseg></trk>\n</gpx>\n"
        return out
    }

    /// ISO 8601 in UTC with milliseconds, e.g. 2026-10-10T17:05:03.125Z (a 25 Hz track needs the fraction).
    public static func timestamp(_ d: Date) -> String {
        iso.string(from: d)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func fmt(_ x: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", x)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
