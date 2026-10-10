import DynoLoggerCore
import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var obd: OBDLink
    @EnvironmentObject private var gps: BLEGPSLink
    @EnvironmentObject private var goPro: GoProLink
    @EnvironmentObject private var phoneGPS: PhoneGPS
    @AppStorage("vehicle") private var vehicle = ""
    @AppStorage("useGoPro") private var useGoPro = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Vehicle name (e.g. Golf R)", text: $vehicle)
                        .disabled(recorder.isRecording)
                }
                Section("Live") {
                    HStack {
                        gauge("RPM", obd.latest[.engineRPM].map { String(Int($0)) })
                        gauge("MPH", speedMPH.map { String(format: "%.0f", $0) })
                        gauge("Boost psi", boost.map { String(format: "%.1f", $0) })
                    }
                }
                Section("Sources") {
                    row("OBD-II", obdText, ok: obd.status == .streaming)
                    row("GPS", gpsText, ok: gps.connected || phoneGPS.latest != nil)
                    row("GoPro", goPro.ready ? (goPro.recording ? "Recording" : "Ready") : "Not connected", ok: goPro.ready)
                    if goPro.ready { Toggle("Record video with each run", isOn: $useGoPro) }
                }
                Section {
                    Button(action: toggle) {
                        HStack {
                            Spacer()
                            Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                                .font(.system(size: 64))
                                .foregroundStyle(recorder.isRecording ? Color.red : Color.green)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    if let start = recorder.startedAt, recorder.isRecording {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text("\(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond)))"
                                 + "  ·  \(recorder.engineRows) OBD rows  ·  \(recorder.trackPoints) GPS points")
                                .font(.footnote.monospacedDigit())
                                .frame(maxWidth: .infinity)
                        }
                    }
                } footer: {
                    Text("For a dyno pull: floor it in one gear from low RPM to redline on a flat, straight road. "
                         + "A coast with the clutch in from 70 to 30 MPH lets the dyno measure rolling resistance.")
                }
                if let e = recorder.error { Text(e).foregroundStyle(.red) }
                if let saved = recorder.lastSaved, !recorder.isRecording {
                    Text("Saved \(saved.lastPathComponent). Open it from the Runs tab.").font(.footnote)
                }
            }
            .navigationTitle("Dyno Logger")
        }
    }

    private var speedMPH: Double? {
        if let k = obd.latest[.vehicleSpeed] { return k / 1.609344 }
        if let s = (gps.latest ?? phoneGPS.latest)?.speed { return s * 2.236936 }
        return nil
    }

    private var boost: Double? {
        guard let map = obd.latest[.map] else { return nil }
        return (map - (obd.latest[.baro] ?? 101.325)) * EngineLog.psiPerKPa
    }

    private var obdText: String {
        switch obd.status {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .initializing: return "Talking to the car"
        case .streaming: return String(format: "%.0f readings/s", obd.rate)
        case .failed(let why): return why
        }
    }

    private var gpsText: String {
        if gps.connected { return "\(gps.name), " + String(format: "%.0f Hz", gps.rate) + (gps.battery.map { ", battery \($0)%" } ?? "") }
        if phoneGPS.latest != nil { return "iPhone, about 1 Hz" + (phoneGPS.accuracy.map { String(format: ", ±%.0f m", $0) } ?? "") }
        return "Waiting for a fix"
    }

    private func toggle() {
        if recorder.isRecording { recorder.stop() } else { recorder.start(vehicle: vehicle, useGoPro: useGoPro) }
    }

    private func gauge(_ label: String, _ value: String?) -> some View {
        VStack {
            Text(value ?? "–").font(.system(.title, design: .monospaced))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ detail: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary).font(.footnote).multilineTextAlignment(.trailing)
        }
    }
}
