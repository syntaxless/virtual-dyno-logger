import Foundation

/// Attaches a Cobb Accessport log to a run. The Accessport logs at a higher rate than OBD-II and reads the car's own boost
/// sensor (OBD-II's manifold pressure tops out near 23 psi of boost on many cars), so its columns are the better source for
/// RPM, speed, pedal and boost. What it lacks is everything else the app records: the weather, the phone's barometer, the
/// vehicle profile, fuel level and, on many cars, ambient temperature and pressure.
///
/// The merged log is the Accessport's own file, every row and column unchanged, with the app's other columns appended. The
/// Accessport's clock is not the phone's, so the two are lined up first: by matching RPM traces against the OBD-II log
/// when there is one, else by matching speed against the GPS track, else by assuming both started together.
public enum AccessportMerge {
    public enum Method: String, Codable, Sendable {
        case rpm, speed, start
    }

    public struct Result: Equatable, Sendable {
        public var csv: String
        /// Session time = Accessport time + offset, seconds.
        public var offset: TimeInterval
        public var method: Method
        /// Mean difference over the overlap: RPM for .rpm, m/s for .speed.
        public var matchError: Double?
        public var rows: Int
        /// The columns that were appended.
        public var added: [String]
    }

    public enum MergeError: Error, Equatable {
        case notAccessport   // no header row with Time and Engine Speed (RPM)
        case tooShort
        case noMatch         // there was something to line up with, but no offset matched
    }

    /// The app's own log columns that the Accessport's replace and so are never carried over.
    static func replaced(_ h: String) -> Bool {
        let l = h.lowercased()
        return l.hasPrefix("time") || l.contains("engine speed") || l.contains("rpm") || l.hasPrefix("vehicle speed")
            || l.contains("pedal") || l.contains("throttle") || l.contains("boost")
    }

    public static func merge(accessport: String, obdLog: String?, track: [(time: TimeInterval, speed: Double)] = [],
                             summary: SessionSummary? = nil) throws -> Result {
        let ap = try Table(accessport)
        guard let ti = ap.column({ $0.contains("time") }), let ri = ap.column({ $0.contains("rpm") || $0.contains("engine speed") })
        else { throw MergeError.notAccessport }
        let si = ap.column { $0.contains("vehicle speed") || ($0.contains("veh") && $0.contains("spd")) }
            ?? ap.column { $0.contains("speed") && !$0.contains("engine") && !$0.contains("rpm") }
        let tScale = ap.header[ti].lowercased().contains("ms") || ap.header[ti].lowercased().contains("milli") ? 0.001 : 1
        let apT = ap.rows.map { $0.num(ti).map { $0 * tScale } }
        guard apT.compactMap({ $0 }).count >= 30 else { throw MergeError.tooShort }

        // Line the two clocks up.
        let obd = try obdLog.map { try Table($0) }
        var offset = 0.0, method = Method.start, err: Double?
        func series(_ t: [Double?], _ rows: [Table.Row], _ k: Int, _ scale: Double) -> [(TimeInterval, Double)] {
            var out: [(TimeInterval, Double)] = []
            for (i, r) in rows.enumerated() { if let x = t[i], let y = r.num(k) { out.append((x, y * scale)) } }
            return out
        }
        if let obd, let oti = obd.column({ $0.hasPrefix("time") }), let ori = obd.column({ $0.contains("engine speed") }) {
            let os = obd.header[oti].lowercased().contains("ms") ? 0.001 : 1
            let ref = series(obd.rows.map { $0.num(oti).map { $0 * os } }, obd.rows, ori, 1)
            guard let m = align(series(apT, ap.rows, ri, 1), ref), m.error <= 250 else { throw MergeError.noMatch }
            offset = m.offset
            err = m.error
            method = .rpm
        } else if let si, track.count >= 30 {
            let ref = track.map { ($0.time, $0.speed) }
            guard let m = align(series(apT, ap.rows, si, speedUnit(ap.header[si])), ref), m.error <= 2.5 else { throw MergeError.noMatch }
            offset = m.offset
            err = m.error
            method = .speed
        }

        // The columns to append: the app's own, except what the Accessport replaces or already has.
        var added: [String] = []
        var cells: [(TimeInterval) -> String] = []
        let has: (String) -> Bool = { name in ap.header.contains { $0.lowercased() == name.lowercased() } }
        let apHasAmbient = ap.column { $0.contains("ambient") && !$0.contains("press") && !$0.contains("baro") } != nil
        let apHasBaro = ap.column { ($0.contains("ambient") && $0.contains("press")) || $0.contains("baro") } != nil
        if let obd, let oti = obd.column({ $0.hasPrefix("time") }) {
            let os = obd.header[oti].lowercased().contains("ms") ? 0.001 : 1
            let times = obd.rows.map { $0.num(oti).map { $0 * os } ?? -.infinity }
            for (k, h) in obd.header.enumerated() where !replaced(h) && !has(h) {
                let l = h.lowercased()
                if apHasAmbient && l.contains("ambient") && !l.contains("press") { continue }
                if apHasBaro && l.contains("ambient") && l.contains("press") { continue }
                added.append(h)
                cells.append { t in
                    // the last OBD row at or before t (the first one before the log starts), carried forward over blanks
                    var i = upperBound(times, t) - 1
                    if i < 0 { i = 0 }
                    while i > 0 && obd.rows[i].cell(k).isEmpty { i -= 1 }
                    return obd.rows[i].cell(k)
                }
            }
        } else if let s = summary {
            // No OBD log: the weather and the vehicle profile straight from the run's summary.
            let extra = EngineLog.csv([EngineSample(time: 0, rpm: 0, speedKmh: 0)], weather: s.weather, start: s.start,
                                      vehicle: s.vehicleProfile).split(separator: "\n").map(String.init)
            if extra.count >= 2 {
                let hh = Table.split(extra[0]), vv = Table.split(extra[1])
                for (k, h) in hh.enumerated() where !replaced(h) && !has(h) && k < vv.count {
                    added.append(h)
                    let v = vv[k]
                    cells.append { _ in v }
                }
            }
        }

        var lines = ap.preamble + [ap.headerLine + added.map { "," + $0 }.joined()]
        for (r, t) in zip(ap.rows, apT) {
            let extra = t.map { t in cells.map { "," + $0(t + offset) }.joined() } ?? String(repeating: ",", count: cells.count)
            lines.append(r.line + extra)
        }
        return Result(csv: lines.joined(separator: "\n") + "\n", offset: offset, method: method, matchError: err,
                      rows: ap.rows.count, added: added)
    }

    static func speedUnit(_ header: String) -> Double {
        let h = header.lowercased()
        if h.contains("km") || h.contains("kph") { return 1 / 3.6 }
        if h.contains("m/s") { return 1 }
        return 0.44704   // mph, the Accessport's default
    }

    /// The offset o (seconds) that best lines up `a` (time, value) with `b`: b(t + o) ~ a(t). Coarse search in 0.5 s steps
    /// over every offset that overlaps at least half of `a` (or 20 s), then refined in 0.02 s steps. Returns the offset and the
    /// mean absolute difference there.
    static func align(_ a: [(TimeInterval, Double)], _ b: [(TimeInterval, Double)]) -> (offset: Double, error: Double)? {
        let b = b.sorted { $0.0 < $1.0 }
        guard a.count >= 30, b.count >= 30, let a0 = a.first?.0, let a1 = a.last?.0, let b0 = b.first?.0, let b1 = b.last?.0
        else { return nil }
        let step = max(1, a.count / 1500)
        let sample = stride(from: 0, to: a.count, by: step).map { a[$0] }
        let bt = b.map(\.0)
        func at(_ t: TimeInterval) -> Double? {
            guard t >= b0, t <= b1 else { return nil }
            let i = max(1, min(b.count - 1, upperBound(bt, t)))
            let (t0, v0) = b[i - 1], (t1, v1) = b[i]
            return t1 > t0 ? v0 + (v1 - v0) * (t - t0) / (t1 - t0) : v0
        }
        let need = min(20, (a1 - a0) / 2)
        func cost(_ o: Double) -> Double? {
            var s = 0.0, n = 0, lo = Double.infinity, hi = -Double.infinity
            for (t, x) in sample { if let y = at(t + o) { s += abs(x - y); n += 1; lo = min(lo, t); hi = max(hi, t) } }
            return n >= 20 && hi - lo >= need ? s / Double(n) : nil
        }
        var best: (Double, Double)?
        var o = b0 - a1
        while o <= b1 - a0 {
            if let c = cost(o), best.map({ c < $0.1 }) ?? true { best = (o, c) }
            o += 0.5
        }
        guard let first = best else { return nil }
        var bo = first.0, bc = first.1
        var f = bo - 0.5
        while f <= bo + 0.5 {
            if let c = cost(f), c < bc { bc = c; bo = f }
            f += 0.02
        }
        return (bo, bc)
    }

    static func upperBound(_ a: [Double], _ x: Double) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// A CSV file: lines before the header (kept as they are), the header, and the rows.
    struct Table {
        var preamble: [String]
        var headerLine: String
        var header: [String]
        var rows: [Row]

        struct Row {
            var line: String
            var cells: [String]
            func cell(_ k: Int) -> String { k < cells.count ? cells[k] : "" }
            func num(_ k: Int) -> Double? { Double(cell(k)) }
        }

        init(_ text: String) throws {
            let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let hi = lines.firstIndex(where: { let l = $0.lowercased(); return l.contains("time") && (l.contains("rpm") || l.contains("engine speed")) })
            else { throw MergeError.notAccessport }
            preamble = Array(lines[..<hi])
            headerLine = lines[hi]
            header = Table.split(lines[hi])
            rows = lines[(hi + 1)...].map { Row(line: $0, cells: Table.split($0)) }
        }

        func column(_ match: (String) -> Bool) -> Int? {
            header.firstIndex { match($0.lowercased()) }
        }

        static func split(_ line: String) -> [String] {
            var out: [String] = [], cur = "", quoted = false
            for ch in line {
                if ch == "\"" { quoted.toggle() } else if ch == "," && !quoted { out.append(cur); cur = "" } else { cur.append(ch) }
            }
            out.append(cur)
            return out.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
}

extension GPX {
    /// Time (seconds since `start`) and speed (m/s) of each point of a GPX the app wrote, for lining up an Accessport log.
    public static func speeds(_ text: String, start: Date) -> [(time: TimeInterval, speed: Double)] {
        var out: [(TimeInterval, Double)] = []
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for chunk in text.components(separatedBy: "<trkpt").dropFirst() {
            guard let t = between(chunk, "<time>", "</time>"), let d = f.date(from: t) ?? ISO8601DateFormatter().date(from: t),
                  let s = between(chunk, "<speed>", "</speed>").flatMap(Double.init) else { continue }
            out.append((d.timeIntervalSince(start), s))
        }
        return out
    }

    private static func between(_ s: String, _ a: String, _ b: String) -> String? {
        guard let r = s.range(of: a), let e = s.range(of: b, range: r.upperBound..<s.endIndex) else { return nil }
        return String(s[r.upperBound..<e.lowerBound])
    }
}
