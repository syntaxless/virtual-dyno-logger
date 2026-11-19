import DynoLoggerCore
import Foundation

/// Screenshot mode. Bluetooth does not work in the iOS Simulator, so App Store screenshots need made-up devices and
/// data. Launch with the argument `-demo` (Xcode: Product > Scheme > Edit Scheme > Run > Arguments) and the app shows a
/// connected OBD-II adapter, RaceBox and GoPro streaming a simulated 3rd-gear pull on a loop, plus three saved runs.
/// Recording works and writes real files from the simulated data. Add `-demoRecording` as well to start recording
/// at launch, and `-demoTab runs` (or record, devices, about) to open on that tab. Nothing here runs without the argument, and it never touches Bluetooth or asks for Location.
@MainActor
enum Demo {
    static let isOn = ProcessInfo.processInfo.arguments.contains("-demo")
    static let startsRecording = ProcessInfo.processInfo.arguments.contains("-demoRecording")
    static let startTab: String? = {
        let a = ProcessInfo.processInfo.arguments
        guard isOn, let i = a.firstIndex(of: "-demoTab"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()

    private static var timer: Timer?

    static let devices: [(name: String, kind: DeviceKind, rssi: Int, connected: Bool)] = [
        ("OBDLink CX", .obd, -48, true),
        ("RaceBox Mini S 1234", .raceBox, -55, true),
        ("GoPro 4821", .goPro, -61, true),
        ("vLinker MC-IOS", .obd, -83, false),
        ("DRAGY-7F21", .dragy, -77, false),
    ]

    static func start(ble: BLEManager, recorder: Recorder, sessions: SessionStore) {
        guard isOn, timer == nil else { return }
        seed(sessions)
        ble.goPro.demoConnect()
        let t0 = Date()
        let pos = Position()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                let s = Pull.sample(at: now.timeIntervalSince(t0))
                ble.obd.demoFeed(OBDReading(date: now, values: s.obd), rate: 18 + 2 * sin(now.timeIntervalSince(t0) / 3))
                let v = s.kmh / 3.6, heading = 75.0 * .pi / 180
                pos.lat += v * 0.05 * cos(heading) / 111_320
                pos.lon += v * 0.05 * sin(heading) / (111_320 * cos(pos.lat * .pi / 180))
                ble.gps.demoFeed(TrackPoint(time: now, latitude: pos.lat, longitude: pos.lon, altitude: 562, speed: v, course: 75,
                                            satellites: 21, hdop: 0.6))
            }
        }
        if startsRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                recorder.start(vehicle: UserDefaults.standard.string(forKey: "vehicle") ?? "Golf R", useGoPro: true)
            }
        }
    }

    private final class Position {
        var lat = 36.2015, lon = -115.0931
    }

    /// Three earlier runs, written as real session folders, so the Runs tab and its Share buttons have something to show.
    private static func seed(_ store: SessionStore) {
        if UserDefaults.standard.string(forKey: "vehicle")?.isEmpty ?? true {
            UserDefaults.standard.set("Golf R", forKey: "vehicle")
        }
        guard store.sessions.isEmpty else { return }
        let day: TimeInterval = 86_400
        let runs: [(String, TimeInterval, Double, Bool)] = [
            ("Golf R", -0.2 * day, 42, true), ("Golf R", -1.1 * day, 36, false), ("GTI", -6.3 * day, 28, false),
        ]
        for (vehicle, ago, length, goPro) in runs {
            let start = Date().addingTimeInterval(ago)
            var engine: [EngineSample] = [], track: [TrackPoint] = []
            var lat = 36.2015, lon = -115.0931
            for i in 0..<Int(length * 18) {
                let t = Double(i) / 18
                let s = Pull.sample(at: t)
                engine.append(EngineSample(time: t, rpm: s.obd[.engineRPM]!, speedKmh: s.kmh, pedalRaw: s.obd[.pedalD],
                                           mapKPa: s.obd[.map], baroKPa: s.obd[.baro], ambientC: s.obd[.ambientTemp]))
            }
            for i in 0..<Int(length * 25) {
                let t = Double(i) / 25, v = Pull.sample(at: t).kmh / 3.6
                lat += v * 0.04 * cos(1.31) / 111_320
                lon += v * 0.04 * sin(1.31) / 92_000
                track.append(TrackPoint(time: start.addingTimeInterval(t), latitude: lat, longitude: lon, altitude: 562,
                                        speed: v, course: 75))
            }
            let summary = SessionSummary(vehicle: vehicle, start: start, end: start.addingTimeInterval(length),
                                         engineRows: engine.count, trackPoints: track.count, trackSource: "RaceBox Mini S 1234",
                                         obdAdapter: "OBDLink CX", pedalSource: .pedal, goProRecorded: goPro)
            try? SessionFiles.write(to: store.root, summary: summary, engine: engine, track: track)
        }
        store.reload()
    }

    /// A 3rd-gear pull on a 16 s loop: cruise, floor it from 2,600 to 7,000 RPM, lift and slow down again.
    enum Pull {
        static func sample(at time: TimeInterval) -> (obd: [OBDPID: Double], kmh: Double) {
            let t = time.truncatingRemainder(dividingBy: 16)
            let rpm: Double, pedal: Double, boostKPa: Double
            switch t {
            case ..<3:
                rpm = 2600 + 20 * sin(t * 2); pedal = 24; boostKPa = -38
            case ..<10:
                let x = (t - 3) / 7
                rpm = 2600 + 4400 * pow(x, 0.9)
                pedal = 80
                boostKPa = min(1, x * 3) * (148 - 18 * max(0, x - 0.6))   // spools by a third of the way, tapers at the top
            default:
                let x = (t - 10) / 6
                rpm = 7000 - 4400 * (1 - pow(1 - x, 2)); pedal = 15; boostKPa = -70 + 30 * x
            }
            let kmh = (rpm / 43.75).rounded()
            let baro = 94.0
            return ([.engineRPM: rpm.rounded(), .vehicleSpeed: kmh, .pedalD: pedal, .map: (baro + boostKPa).rounded(),
                     .baro: baro, .ambientTemp: 21], kmh)
        }
    }
}
