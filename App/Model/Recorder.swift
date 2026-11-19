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
    @Published var error: String?

    private let ble: BLEManager
    private let phoneGPS: PhoneGPS
    private let sessions: SessionStore
    private var engine: [EngineSample] = []
    private var externalTrack: [TrackPoint] = []
    private var phoneTrack: [TrackPoint] = []
    private var usedGoPro = false

    init(ble: BLEManager, phoneGPS: PhoneGPS, sessions: SessionStore) {
        self.ble = ble
        self.phoneGPS = phoneGPS
        self.sessions = sessions
        ble.obd.onReading = { [weak self] r in self?.take(r) }
        ble.gps.onPoint = { [weak self] p in self?.takeExternal(p) }
        phoneGPS.onPoint = { [weak self] p in self?.takePhone(p) }
        if !Demo.isOn { phoneGPS.start() }   // warm up the fix before the first run
    }

    func start(vehicle: String, useGoPro: Bool) {
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
        if !Demo.isOn { phoneGPS.start() }
        usedGoPro = useGoPro && ble.goPro.ready
        if usedGoPro { ble.goPro.setRecording(true) }
        UserDefaults.standard.set(vehicle, forKey: "vehicle")
    }

    func stop() {
        guard isRecording, let start = startedAt else { return }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        if usedGoPro { ble.goPro.setRecording(false) }

        let external = !externalTrack.isEmpty
        let summary = SessionSummary(
            vehicle: UserDefaults.standard.string(forKey: "vehicle") ?? "",
            start: start, end: Date(),
            engineRows: engine.count,
            trackPoints: external ? externalTrack.count : phoneTrack.count,
            trackSource: external ? ble.gps.name : (phoneTrack.isEmpty ? nil : "iPhone"),
            obdAdapter: engine.isEmpty ? nil : ble.obd.name,
            pedalSource: engine.isEmpty ? nil : ble.obd.pedalSource,
            goProRecorded: usedGoPro
        )
        let engine = self.engine, track = external ? externalTrack : phoneTrack, root = sessions.root
        guard !engine.isEmpty || !track.isEmpty else { error = "Nothing was recorded: no OBD-II or GPS data came in."; return }
        Task {
            do {
                let url = try await Task.detached {
                    try SessionFiles.write(to: root, summary: summary, engine: engine, track: track)
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
            mapKPa: r.values[.map], baroKPa: r.values[.baro], ambientC: r.values[.ambientTemp]
        ))
        engineRows = engine.count
    }

    private func takeExternal(_ p: TrackPoint) {
        guard isRecording else { return }
        externalTrack.append(p)
        trackPoints = externalTrack.count
    }

    private func takePhone(_ p: TrackPoint) {
        guard isRecording else { return }
        phoneTrack.append(p)
        if externalTrack.isEmpty { trackPoints = phoneTrack.count }
    }
}
