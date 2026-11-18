import DynoLoggerCore
import Foundation
import UIKit

/// Records a run: collects OBD readings and GPS fixes between Start and Stop, starts and stops the GoPro with it, and
/// writes the session folder the Virtual Dyno reads.
@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var engineRows = 0
    @Published private(set) var trackPoints = 0
    @Published private(set) var lastSaved: URL?
    @Published private(set) var saving = false
    @Published var error: String?
    /// The latest weather snapshot of this run (or the last run), for the Record screen.
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherState: WeatherState = .off

    enum WeatherState: Equatable { case off, waitingForFix, fetching, got, failed }

    let barometer = PhoneBarometer()

    private let ble: BLEManager
    private let phoneGPS: PhoneGPS
    private let sessions: SessionStore
    private var engine: [EngineSample] = []
    private var externalTrack: [TrackPoint] = []
    private var phoneTrack: [TrackPoint] = []
    private var usedGoPro = false
    private var startWeather: Task<WeatherSnapshot?, Never>?

    init(ble: BLEManager, phoneGPS: PhoneGPS, sessions: SessionStore) {
        self.ble = ble
        self.phoneGPS = phoneGPS
        self.sessions = sessions
        ble.obd.onReading = { [weak self] r in self?.take(r) }
        ble.gps.onPoint = { [weak self] p in self?.takeExternal(p) }
        phoneGPS.onPoint = { [weak self] p in self?.takePhone(p) }
        if !Demo.isOn { phoneGPS.start() }   // warm up the fix before the first run
    }

    /// fetchWeather: the "Fetch the weather for each run" switch on the Record screen (on by default).
    func start(vehicle: String, useGoPro: Bool, fetchWeather: Bool = true) {
        guard !isRecording else { return }
        engine = []
        externalTrack = []
        phoneTrack = []
        engineRows = 0
        trackPoints = 0
        error = nil
        startedAt = Date()
        isRecording = true
        UIApplication.shared.isIdleTimerDisabled = true
        if !Demo.isOn { phoneGPS.start(); barometer.start() }
        weather = nil
        weatherState = .off
        startWeather = fetchWeather && !Demo.isOn ? fetchWeatherHere() : nil
        usedGoPro = useGoPro && ble.goPro.ready
        if usedGoPro { ble.goPro.setRecording(true) }
        UserDefaults.standard.set(vehicle, forKey: "vehicle")
    }

    func stop() {
        guard isRecording, let start = startedAt else { return }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        barometer.stop()
        if usedGoPro { ble.goPro.setRecording(false) }
        let first = startWeather, last = first == nil ? nil : fetchWeatherHere()
        startWeather = nil

        let external = !externalTrack.isEmpty
        let summary = SessionSummary(
            vehicle: UserDefaults.standard.string(forKey: "vehicle") ?? "",
            start: start, end: Date(),
            engineRows: engine.count,
            trackPoints: external ? externalTrack.count : phoneTrack.count,
            trackSource: external ? ble.gps.name : (phoneTrack.isEmpty ? nil : "iPhone"),
            obdAdapter: engine.isEmpty ? nil : ble.obd.name,
            pedalSource: engine.isEmpty ? nil : ble.obd.pedalSource,
            goProRecorded: usedGoPro,
            phoneBarometer: engine.contains { $0.phoneBaroKPa != nil } || externalTrack.contains { $0.pressure != nil }
                || phoneTrack.contains { $0.pressure != nil },
            vehicleProfile: VehicleProfiles.profile(for: UserDefaults.standard.string(forKey: "vehicle") ?? "")
        )
        let engine = self.engine, track = external ? externalTrack : phoneTrack, root = sessions.root
        guard !engine.isEmpty || !track.isEmpty else { error = "Nothing was recorded: no OBD-II or GPS data came in."; return }
        saving = true
        Task {
            defer { saving = false }
            // The weather from the start of the run, and one more now (each gives up after a few seconds).
            var summary = summary
            let a = await first?.value, b = await last?.value
            summary.weather = [a, b].compactMap { $0 }.reduce(into: [WeatherSnapshot]()) { out, w in
                if !out.contains(where: { $0.time == w.time && $0.latitude == w.latitude && $0.longitude == w.longitude }) { out.append(w) }
            }
            do {
                let final = summary
                let url = try await Task.detached {
                    try SessionFiles.write(to: root, summary: final, engine: engine, track: track)
                }.value
                lastSaved = url
                sessions.reload()
            } catch {
                self.error = "Could not save the session: \(error.localizedDescription)"
            }
        }
    }

    private func take(_ r: OBDReading) {
        guard isRecording, let start = startedAt,
              let rpm = r.values[.engineRPM], let speed = r.values[.vehicleSpeed] else { return }
        engine.append(EngineSample(
            time: r.date.timeIntervalSince(start),
            rpm: rpm, speedKmh: speed,
            pedalRaw: r.values[.pedalD] ?? r.values[.throttle],
            mapKPa: r.values[.map], baroKPa: r.values[.baro], ambientC: r.values[.ambientTemp],
            phoneBaroKPa: barometer.pressureKPa, fuelPercent: r.values[.fuelLevel]
        ))
        engineRows = engine.count
    }

    private func takeExternal(_ p: TrackPoint) {
        guard isRecording else { return }
        externalTrack.append(withBarometer(p))
        trackPoints = externalTrack.count
    }

    private func takePhone(_ p: TrackPoint) {
        guard isRecording else { return }
        phoneTrack.append(withBarometer(p))
        if externalTrack.isEmpty { trackPoints = phoneTrack.count }
    }

    private func withBarometer(_ p: TrackPoint) -> TrackPoint {
        var p = p
        p.relativeAltitude = barometer.relativeAltitude
        p.pressure = barometer.pressureKPa.map { $0 * 10 }
        return p
    }

    /// Fetches the weather where the phone is, waiting up to 20 s for a first GPS fix (external GPS or the iPhone's).
    private func fetchWeatherHere() -> Task<WeatherSnapshot?, Never> {
        weatherState = .waitingForFix
        return Task { [weak self] in
            var fix: TrackPoint?
            for _ in 0..<40 {
                fix = self?.ble.gps.latest ?? self?.phoneGPS.latest
                if fix != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let self else { return nil }
            guard let fix else {
                if self.weather == nil { self.weatherState = .failed }
                return nil
            }
            self.weatherState = .fetching
            let w = await WeatherService.current(latitude: fix.latitude, longitude: fix.longitude)
            if let w {
                self.weather = w
                self.weatherState = .got
            } else if self.weather == nil {
                self.weatherState = .failed
            } else {
                self.weatherState = .got
            }
            return w
        }
    }
}
