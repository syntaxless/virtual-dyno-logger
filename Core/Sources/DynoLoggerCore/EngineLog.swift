import Foundation

/// One OBD-II reading, merged from one poll of the ECU. Nil means the value was not read in that poll.
public struct EngineSample: Equatable, Sendable {
    /// Seconds since the session started.
    public var time: TimeInterval
    public var rpm: Double
    public var speedKmh: Double
    /// Accelerator pedal (PID 0x49) or throttle (PID 0x11), in % exactly as the ECU reports it.
    public var pedalRaw: Double?
    /// Intake manifold absolute pressure (PID 0x0B), kPa.
    public var mapKPa: Double?
    /// Barometric pressure (PID 0x33), kPa.
    public var baroKPa: Double?
    /// Ambient air temperature (PID 0x46), Celsius.
    public var ambientC: Double?

    public init(time: TimeInterval, rpm: Double, speedKmh: Double, pedalRaw: Double? = nil,
                mapKPa: Double? = nil, baroKPa: Double? = nil, ambientC: Double? = nil) {
        self.time = time
        self.rpm = rpm
        self.speedKmh = speedKmh
        self.pedalRaw = pedalRaw
        self.mapKPa = mapKPa
        self.baroKPa = baroKPa
        self.ambientC = ambientC
    }
}

public enum PedalSource: String, Codable, Sendable {
    case pedal      // PID 0x49, accelerator pedal position D
    case throttle   // PID 0x11, throttle position
}

/// Writes the engine log in the layout of a Cobb Accessport .csv, which is what the Virtual Dyno's "Cobb Accessport
/// log" box parses (`parse()` in virtual-dyno/index.html). What the dyno needs from it:
/// - a header row containing "Time" and "Engine Speed (RPM)", and a "Vehicle Speed" column with its unit in the name
///   (km/h here, the resolution OBD-II reports, so nothing is rounded twice);
/// - "Time (msec)", strictly increasing (the dyno drops a row whose time does not increase);
/// - "Accel. Pedal Position (%)" (or "Throttle Position (%)") scaled so a floored pedal reads 100: the dyno only
///   counts a pull when the pedal is at or above its "Throttle Position >=" field (90 by default), and OBD pedal
///   sensors usually rest near 15 % and top out near 80 %;
/// - optional "Ambient Air Temp (F)", "Ambient Pressure (psi)" and "Boost Press. (psi)" (gauge), which fill the
///   air temperature, density altitude and Peak Boost Pressure tile.
public enum EngineLog {
    public static let psiPerKPa = 1 / 6.89476
    static let standardBaroKPa = 101.325

    public static func csv(_ samples: [EngineSample], pedalSource: PedalSource = .pedal) -> String {
        let hasPedal = samples.contains { $0.pedalRaw != nil }
        let hasMAP = samples.contains { $0.mapKPa != nil }
        let hasBaro = samples.contains { $0.baroKPa != nil }
        let hasAmbient = samples.contains { $0.ambientC != nil }
        let pedal = PedalScale(samples.compactMap(\.pedalRaw))

        var header = ["Time (msec)", "Engine Speed (RPM)", "Vehicle Speed (km/h)"]
        if hasPedal { header.append(pedalSource == .pedal ? "Accel. Pedal Position (%)" : "Throttle Position (%)") }
        if hasAmbient { header.append("Ambient Air Temp (F)") }
        if hasBaro { header.append("Ambient Pressure (psi)") }
        if hasMAP { header.append("Boost Press. (psi)") }

        var lines = [header.joined(separator: ",")]
        var lastMs = Int.min
        // Ambient temperature and pressure are polled slowly, so the last reading is carried forward.
        var baro: Double?
        var ambient: Double?
        for s in samples {
            if let b = s.baroKPa { baro = b }
            if let a = s.ambientC { ambient = a }
            let ms = Int((s.time * 1000).rounded())
            guard ms > lastMs, s.rpm.isFinite, s.speedKmh.isFinite else { continue }
            lastMs = ms
            var row = [String(ms), String(Int(s.rpm.rounded())), String(Int(s.speedKmh.rounded()))]
            if hasPedal { row.append(s.pedalRaw.map { fmt(pedal.apply($0), 1) } ?? "") }
            if hasAmbient { row.append(ambient.map { fmt($0 * 9 / 5 + 32, 1) } ?? "") }
            if hasBaro { row.append(baro.map { fmt($0 * psiPerKPa, 2) } ?? "") }
            if hasMAP {
                row.append(s.mapKPa.map { fmt(($0 - (baro ?? standardBaroKPa)) * psiPerKPa, 1) } ?? "")
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func fmt(_ x: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", x)
    }
}

/// Maps the pedal's resting and floored readings to 0 and 100 %. Both ends are taken from the session itself
/// (2nd and 99.5th percentiles, so a single glitch does not set them). A session where the pedal never moved
/// more than 25 points has no floored reading to learn from and is written as reported.
public struct PedalScale: Equatable, Sendable {
    public let low: Double
    public let high: Double

    public init(low: Double, high: Double) {
        self.low = low
        self.high = high
    }

    public init(_ values: [Double]) {
        let v = values.filter(\.isFinite).sorted()
        guard v.count >= 10 else { self.init(low: 0, high: 100); return }
        let lo = v[Int(Double(v.count - 1) * 0.02)]
        let hi = v[Int(Double(v.count - 1) * 0.995)]
        if hi - lo < 25 { self.init(low: 0, high: 100) } else { self.init(low: lo, high: hi) }
    }

    public func apply(_ x: Double) -> Double {
        min(100, max(0, (x - low) / (high - low) * 100))
    }
}
