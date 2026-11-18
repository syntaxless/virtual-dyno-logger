import Foundation

/// Finds the pulls and coasts in a run the way the Virtual Dyno does, so the app can say while you are still parked
/// whether the run is usable, and guide the next step. The coast search is a port of the dyno's `findCoasts()`
/// (virtual-dyno/index.html) with the same thresholds; if one changes, change the other.
public enum RunCheck {
    public static let mph = 0.44704

    public struct Pull: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var rpmFrom: Double
        public var rpmTo: Double
        /// The highest pedal seen in the pull, scaled 0-100 like the log.
        public var peakPedal: Double
        /// True when RPM per speed stayed within 4% of its median: one gear, no clutch slip.
        public var oneGear: Bool
        public var duration: TimeInterval { end - start }
        /// The dyno's default needs at least 90% pedal; a pull of 3 s or more in one gear from 3,000 RPM or lower
        /// gives a curve worth reading.
        public var good: Bool { oneGear && duration >= 3 && rpmTo - rpmFrom >= 2000 }
    }

    public enum CoastStatus: String, Sendable {
        case good          // 30 s or more, from 60 MPH or faster down to 40 or slower
        case short         // clutch in and no brakes, but too short or too narrow a speed range for a firm number
        case inGear        // RPM followed speed: engine braking, not usable
    }

    public struct Coast: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var fromMPH: Double
        public var toMPH: Double
        public var status: CoastStatus
        /// Degrees from true north, from the GPS track (nil without one).
        public var heading: Double?
        /// Where the coast was, from the GPS track: the middle point.
        public var latitude: Double?
        public var longitude: Double?
        public var duration: TimeInterval { end - start }
    }

    /// Pulls: the pedal at or above `pedalMin` (scaled %) for 2 s or more with RPM climbing.
    public static func pulls(_ e: [EngineSample], scale: PedalScale, pedalMin: Double = 90) -> [Pull] {
        var out: [Pull] = []
        var i = 0
        while i < e.count {
            guard let p = e[i].pedalRaw, scale.apply(p) >= pedalMin else { i += 1; continue }
            var j = i
            var peak = scale.apply(p)
            while j + 1 < e.count, let q = e[j + 1].pedalRaw, scale.apply(q) >= pedalMin { j += 1; peak = max(peak, scale.apply(q)) }
            let seg = e[i...j]
            if e[j].time - e[i].time >= 2, let lo = seg.map(\.rpm).min(), let hi = seg.map(\.rpm).max(), hi - lo >= 500 {
                let ratios = seg.filter { $0.speedKmh > 10 }.map { $0.rpm / $0.speedKmh }.sorted()
                let med = ratios.isEmpty ? 0 : ratios[ratios.count / 2]
                // A shift shows as a run of ratios well off the median; a sample or two off is noise from whole-km/h speed.
                let off = ratios.filter { abs($0 / med - 1) > 0.04 }.count
                out.append(Pull(start: e[i].time, end: e[j].time, rpmFrom: e[i].rpm, rpmTo: seg.map(\.rpm).max() ?? e[j].rpm,
                                peakPedal: peak, oneGear: med > 0 && Double(off) <= 0.1 * Double(ratios.count)))
            }
            i = j + 1
        }
        return out
    }

    /// Coasts, as the dyno finds them: the pedal at 1.5% or less for 5 s or more, and RPM per speed falling 8% below
    /// its in-gear value for 0.3 s (the clutch is in). It ends when RPM climbs 300 (clutch out) or the car slows far
    /// faster than road and air explain (brakes). `kap` is 0.5 rho Cd A / mass, 1/m.
    public static func coasts(_ e: [EngineSample], scale: PedalScale, track: [TrackPoint] = [], start: Date? = nil,
                              kap: Double = 0.5 * 1.2 * 0.32 * 2.2 / 1600) -> [Coast] {
        let n = e.count
        let t = e.map(\.time), v = e.map { $0.speedKmh / 3.6 }, rpm = e.map(\.rpm)
        let off: (Int) -> Bool = { i in e[i].pedalRaw.map { scale.apply($0) <= 1.5 } ?? false }
        var out: [Coast] = []
        var s = 1
        while s < n {
            defer { s += 1 }
            guard off(s), !off(s - 1) else { continue }
            var en = s
            while en + 1 < n && off(en + 1) { en += 1 }
            let s0 = s
            s = en
            guard t[en] - t[s0] >= 5 else { continue }
            var r: [Double] = []
            var i = s0 - 1
            while i >= 0 && t[s0] - t[i] < 0.8 { if v[i] > 3 && rpm[i] > 0 { r.append(rpm[i] / v[i]) }; i -= 1 }
            guard r.count >= 5 else { continue }
            r.sort()
            let r0 = r[r.count / 2]
            var c = -1
            for k in s0...en {
                if v[k] > 0 && rpm[k] / v[k] < 0.92 * r0 {
                    if c < 0 { c = k }
                    if t[k] - t[c] >= 0.3 { break }
                } else { c = -1 }
            }
            if c < 0 || t[en] - t[c] < 0.3 {
                if t[en] - t[s0] >= 8 && v[s0] - v[en] >= 10 * mph {
                    out.append(coast(t[s0], t[en], v[s0], v[en], .inGear, track, start))
                }
                continue
            }
            let dt = (t[en] - t[s0]) / Double(max(1, en - s0)), hw = max(1, Int((0.75 / dt).rounded()))
            var a = c
            while a < en && t[a] - t[c] < 0.8 { a += 1 }
            var b = en, lo = rpm[a]
            for k in a...en { lo = min(lo, rpm[k]); if rpm[k] > lo + 300 { b = k - 1; break } }
            if a + hw <= b - hw {
                for k in (a + hw)...(b - hw) {
                    let w = (k - hw...k + hw).map { t[$0] - t[k] }, y = (k - hw...k + hw).map { v[$0] }
                    let mx = w.reduce(0, +) / Double(w.count), my = y.reduce(0, +) / Double(y.count)
                    var sxy = 0.0, sxx = 0.0
                    for q in w.indices { sxy += (w[q] - mx) * (y[q] - my); sxx += (w[q] - mx) * (w[q] - mx) }
                    if sxx > 0 && -sxy / sxx > kap * v[k] * v[k] + 0.15 + 0.9 { b = k - hw; break }
                }
            }
            b -= Int((0.4 / dt).rounded())
            guard b - a >= 20 else { continue }
            let from = v[a] / mph, to = v[b] / mph
            let good = t[b] - t[a] >= 30 && from >= 60 && to <= 40
            out.append(coast(t[a], t[b], v[a], v[b], good ? .good : .short, track, start))
        }
        return out
    }

    private static func coast(_ t0: TimeInterval, _ t1: TimeInterval, _ v0: Double, _ v1: Double, _ st: CoastStatus,
                              _ track: [TrackPoint], _ start: Date?) -> Coast {
        var c = Coast(start: t0, end: t1, fromMPH: v0 / mph, toMPH: v1 / mph, status: st)
        if let start {
            let pts = track.filter { let x = $0.time.timeIntervalSince(start); return x >= t0 && x <= t1 }
            if let p = pts.first, let q = pts.last, pts.count >= 2 {
                c.heading = bearing(p.latitude, p.longitude, q.latitude, q.longitude)
                let m = pts[pts.count / 2]
                c.latitude = m.latitude
                c.longitude = m.longitude
            }
        }
        return c
    }

    /// Initial bearing from one point to another, degrees from true north.
    public static func bearing(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180, p1 = la1 * r, p2 = la2 * r, dl = (lo2 - lo1) * r
        let y = sin(dl) * cos(p2), x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Metres between two points (equirectangular: fine at road scale).
    public static func distance(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = Double.pi / 180, x = (lo2 - lo1) * r * cos((la1 + la2) / 2 * r), y = (la2 - la1) * r
        return 6_371_000 * (x * x + y * y).squareRoot()
    }

    /// Two good coasts on the same stretch in opposite directions: headings 180 +/- 30 degrees apart and their middle
    /// points within 1 km. Averaging such a pair cancels the hill and most of the wind, which is what lets the dyno fit
    /// drag as well as rolling resistance.
    public static func isOppositePair(_ a: Coast, _ b: Coast) -> Bool {
        guard a.status == .good, b.status == .good, let h1 = a.heading, let h2 = b.heading else { return false }
        // the angle between the two headings, 0 to 180; opposite directions are 180
        let angle = abs((h1 - h2 + 540).truncatingRemainder(dividingBy: 360) - 180)
        guard angle >= 150 else { return false }
        if let la = a.latitude, let lo = a.longitude, let lb = b.latitude, let ob = b.longitude {
            return distance(la, lo, lb, ob) <= 1000
        }
        return false
    }
}

/// The guided run: what to do next, given what the run holds so far. The app shows `steps` as a checklist and
/// `prompt` as the line to read while driving.
public struct RunGuide: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        case coastOne, coastTwo, pull
    }

    public var pulls: [RunCheck.Pull]
    public var coasts: [RunCheck.Coast]
    public var wantCoasts: Bool

    public init(pulls: [RunCheck.Pull], coasts: [RunCheck.Coast], wantCoasts: Bool = true) {
        self.pulls = pulls
        self.coasts = coasts
        self.wantCoasts = wantCoasts
    }

    public var goodCoasts: [RunCheck.Coast] { coasts.filter { $0.status == .good } }
    public var hasPair: Bool {
        let g = goodCoasts
        for i in g.indices { for j in g.indices where j > i { if RunCheck.isOppositePair(g[i], g[j]) { return true } } }
        return false
    }

    public func done(_ s: Step) -> Bool {
        switch s {
        case .coastOne: return !goodCoasts.isEmpty
        case .coastTwo: return hasPair
        case .pull: return pulls.contains { $0.good }
        }
    }

    public var next: Step? {
        if wantCoasts { for s in [Step.coastOne, .coastTwo] where !done(s) { return s } }
        return done(.pull) ? nil : .pull
    }

    /// What to do next, in one or two sentences.
    public var prompt: String {
        switch next {
        case .coastOne:
            return "Coast 1: on a flat, straight road, get to 70 MPH or more, then clutch in (or neutral) and coast to "
                + "30 MPH without braking. Keep the wheel straight."
        case .coastTwo:
            return "Coast 2: turn around and coast the same stretch the other way, from 70 to 30 MPH. Two directions "
                + "cancel the hill and the wind, so the dyno can measure drag as well as rolling resistance."
        case .pull:
            return "Pull: in one gear (3rd or 4th), floor it from about 2,500 RPM to redline, then lift."
        case nil:
            return "All done. Stop the run, then load the two files into the Virtual Dyno."
        }
    }

    /// What the last coast or pull said, for the line under the checklist.
    public var lastResult: String? {
        let lastCoast = coasts.last, lastPull = pulls.last
        if let c = lastCoast, lastPull.map({ $0.end < c.end }) ?? true {
            let run = String(format: "%.0f s, %.0f to %.0f MPH", c.duration, c.fromMPH, c.toMPH)
            switch c.status {
            case .good:
                if coasts.filter({ $0.status == .good }).count >= 2 && !hasPair {
                    return "Coast OK (\(run)), but not the opposite way on the same stretch as the first. Try again there."
                }
                return "Coast OK: \(run)."
            case .short: return "Coast too short (\(run)). Start at 60 MPH or more and let it roll to 40 or slower, about 30 s or more."
            case .inGear: return "That slow-down was in gear (\(run)). Press the clutch in or shift to neutral."
            }
        }
        if let p = lastPull {
            let run = String(format: "%.1f s, %.0f to %.0f RPM", p.duration, p.rpmFrom, p.rpmTo)
            if !p.oneGear { return "That pull changed gear or slipped (\(run)). Stay in one gear." }
            if p.good { return "Pull OK: \(run)." }
            return "Pull too short (\(run)). Start lower, about 2,500 RPM, and hold it to redline."
        }
        return nil
    }
}
