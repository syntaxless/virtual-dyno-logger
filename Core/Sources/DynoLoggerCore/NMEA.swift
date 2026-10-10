import Foundation

/// Turns a stream of NMEA 0183 text (from a BLE GPS that sends it over the Nordic UART service, or any serial GPS)
/// into track points. A point is made from each valid RMC sentence (time, date, position, speed, course); the GGA
/// sentence with the same time adds altitude, satellites and HDOP.
public struct NMEAAssembler {
    private var buffer = ""
    private var gga: (time: String, altitude: Double?, satellites: Int?, hdop: Double?)?

    public init() {}

    public mutating func feed(_ data: Data) -> [TrackPoint] {
        buffer += String(decoding: data, as: UTF8.self)
        var points: [TrackPoint] = []
        while let nl = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if let p = take(line) { points.append(p) }
        }
        if buffer.count > 4096 { buffer = "" }   // not NMEA
        return points
    }

    mutating func take(_ line: String) -> TrackPoint? {
        guard let f = NMEA.fields(line) else { return nil }
        let type = f[0].suffix(3)
        if type == "GGA", f.count > 9 {
            gga = (f[1], Double(f[9]), Int(f[7]), Double(f[8]))
            return nil
        }
        guard type == "RMC", f.count > 9, f[2] == "A",
              let lat = NMEA.coordinate(f[3], f[4]), let lon = NMEA.coordinate(f[5], f[6]),
              let time = NMEA.date(time: f[1], date: f[9]) else { return nil }
        var p = TrackPoint(time: time, latitude: lat, longitude: lon,
                           speed: Double(f[7]).map { $0 * 1852 / 3600 }, course: Double(f[8]))
        if let g = gga, g.time == f[1] {
            p.altitude = g.altitude
            p.satellites = g.satellites
            p.hdop = g.hdop
        }
        return p
    }
}

public enum NMEA {
    /// The comma-separated fields of a sentence whose checksum is right, without the "$" and "*hh".
    public static func fields(_ line: String) -> [String]? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("$"), let star = s.lastIndex(of: "*") else { return nil }
        let body = s[s.index(after: s.startIndex)..<star]
        guard let sum = UInt8(s[s.index(after: star)...].prefix(2), radix: 16),
              body.utf8.reduce(UInt8(0), ^) == sum else { return nil }
        return body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    /// "4807.038", "N" -> 48.1173
    static func coordinate(_ value: String, _ hemisphere: String) -> Double? {
        guard let v = Double(value) else { return nil }
        let deg = (v / 100).rounded(.towardZero)
        let d = deg + (v - deg * 100) / 60
        return hemisphere == "S" || hemisphere == "W" ? -d : d
    }

    /// "170503.25" and "101026" (ddmmyy) -> a UTC date.
    static func date(time: String, date: String) -> Date? {
        guard time.count >= 6, date.count == 6,
              let hh = Int(time.prefix(2)), let mm = Int(time.dropFirst(2).prefix(2)),
              let ss = Double(time.dropFirst(4)),
              let day = Int(date.prefix(2)), let mon = Int(date.dropFirst(2).prefix(2)), let yy = Int(date.suffix(2))
        else { return nil }
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        c.year = 2000 + yy
        c.month = mon
        c.day = day
        c.hour = hh
        c.minute = mm
        c.second = 0
        guard let base = Calendar(identifier: .gregorian).date(from: c) else { return nil }
        return base.addingTimeInterval(ss)
    }
}
