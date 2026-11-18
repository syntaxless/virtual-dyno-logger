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
    /// The iPhone's own barometer (CMAltimeter), kPa. Cabin pressure, which is within a few hundredths of a psi of the
    /// air outside with the windows up.
    public var phoneBaroKPa: Double?

    public init(time: TimeInterval, rpm: Double, speedKmh: Double, pedalRaw: Double? = nil,
                mapKPa: Double? = nil, baroKPa: Double? = nil, ambientC: Double? = nil, phoneBaroKPa: Double? = nil) {
        self.time = time
        self.rpm = rpm
        self.speedKmh = speedKmh
        self.pedalRaw = pedalRaw
        self.mapKPa = mapKPa
        self.baroKPa = baroKPa
        self.ambientC = ambientC
        self.phoneBaroKPa = phoneBaroKPa
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
///   air temperature, density altitude and Peak Boost Pressure tile. Ambient Pressure is the car's barometric sensor;
///   when the car does not report one, it is the iPhone's barometer instead.
///
/// After those, columns the dyno can choose from (their names avoid "ambient", "baro", "speed" first and "time", so
/// the dyno's own column matching above never picks them by mistake):
/// - "Phone Pressure (psi)": the iPhone's barometer, always, so the dyno can compare it with the car's;
/// - "Weather Humidity (%)", "Weather Wind (MPH)", "Weather Wind From (deg)", "Weather Air Temp (F)",
///   "Weather Sea-Level Pressure (hPa)": Open-Meteo's current conditions where the phone was, from the snapshot
///   nearest in time to each row (one is taken at the start of the run and one at the end).
public enum EngineLog {
    public static let psiPerKPa = 1 / 6.89476
    static let standardBaroKPa = 101.325

    public static func csv(_ samples: [EngineSample], pedalSource: PedalSource = .pedal,
                           weather: [WeatherSnapshot] = [], start: Date? = nil) -> String {
        let hasPedal = samples.contains { $0.pedalRaw != nil }
        let hasMAP = samples.contains { $0.mapKPa != nil }
        let hasBaro = samples.contains { $0.baroKPa != nil }
        let hasAmbient = samples.contains { $0.ambientC != nil }
        let hasPhoneBaro = samples.contains { $0.phoneBaroKPa != nil }
        let wx = start == nil ? [] : weather.sorted { $0.time < $1.time }
        let wxCols: [(String, (WeatherSnapshot) -> String?)] = [
            ("Weather Humidity (%)", { $0.humidity.map { fmt($0, 0) } }),
            ("Weather Wind (MPH)", { $0.windSpeedMPH.map { fmt($0, 1) } }),
            ("Weather Wind From (deg)", { $0.windFromDeg.map { fmt($0, 0) } }),
            ("Weather Air Temp (F)", { $0.temperatureC.map { fmt($0 * 9 / 5 + 32, 1) } }),
            ("Weather Sea-Level Pressure (hPa)", { $0.pressureMSLhPa.map { fmt($0, 1) } }),
        ].filter { col in wx.contains { col.1($0) != nil } }
        let pedal = PedalScale(samples.compactMap(\.pedalRaw))

        var header = ["Time (msec)", "Engine Speed (RPM)", "Vehicle Speed (km/h)"]
        if hasPedal { header.append(pedalSource == .pedal ? "Accel. Pedal Position (%)" : "Throttle Position (%)") }
        if hasAmbient { header.append("Ambient Air Temp (F)") }
        if hasBaro || hasPhoneBaro { header.append("Ambient Pressure (psi)") }
        if hasMAP { header.append("Boost Press. (psi)") }
        if hasPhoneBaro { header.append("Phone Pressure (psi)") }
        header += wxCols.map(\.0)

        var lines = [header.joined(separator: ",")]
        var lastMs = Int.min
        // Ambient temperature and pressure are polled slowly, so the last reading is carried forward.
        var baro: Double?
        var ambient: Double?
        var phone: Double?
        for s in samples {
            if let b = s.baroKPa { baro = b }
            if let a = s.ambientC { ambient = a }
            if let p = s.phoneBaroKPa { phone = p }
            let ms = Int((s.time * 1000).rounded())
            guard ms > lastMs, s.rpm.isFinite, s.speedKmh.isFinite else { continue }
            lastMs = ms
            var row = [String(ms), String(Int(s.rpm.rounded())), String(Int(s.speedKmh.rounded()))]
            if hasPedal { row.append(s.pedalRaw.map { fmt(pedal.apply($0), 1) } ?? "") }
            if hasAmbient { row.append(ambient.map { fmt($0 * 9 / 5 + 32, 1) } ?? "") }
            // A car that reports baro at all keeps its own column; the phone fills it only for cars that never do.
            if hasBaro { row.append(baro.map { fmt($0 * psiPerKPa, 2) } ?? "") }
            else if hasPhoneBaro { row.append(phone.map { fmt($0 * psiPerKPa, 2) } ?? "") }
            if hasMAP {
                row.append(s.mapKPa.map { fmt(($0 - (baro ?? phone ?? standardBaroKPa)) * psiPerKPa, 1) } ?? "")
            }
            if hasPhoneBaro { row.append(phone.map { fmt($0 * psiPerKPa, 3) } ?? "") }
            if !wxCols.isEmpty, let start {
                let t = start.addingTimeInterval(s.time)
                let w = wx.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }!
                row += wxCols.map { $0.1(w) ?? "" }
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
