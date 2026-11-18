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
    @AppStorage("fetchWeather") private var fetchWeather = true
    @FocusState private var editingVehicle: Bool
    @State private var editingProfile = false

    var body: some View {
        TerminalScreen(path: "logger", command: "./dyno-logger",
                       status: recorder.isRecording ? "● REC" : "idle",
                       statusColor: recorder.isRecording ? Color(hex: 0x8A1A10) : Phosphor.ink) {
            Panel(title: "Vehicle") {
                TextField("", text: $vehicle, prompt: Text("e.g. Golf R").foregroundColor(Phosphor.mut))
                    .focused($editingVehicle)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .terminalField(focused: editingVehicle)
                    .disabled(recorder.isRecording)
                Text("Names the files, like the dyno's Print image: GolfR_2026-11-18_170503.csv")
                    .font(.vtCaption).foregroundStyle(Phosphor.mut)
                Button { editingProfile = true } label: { Text(profileText) }
                    .buttonStyle(BracketButtonStyle())
                    .disabled(recorder.isRecording)
            }
            .sheet(isPresented: $editingProfile) { VehicleProfileView(vehicle: vehicle) }

            StatTile(title: "Engine Speed", value: obd.latest[.engineRPM].map { $0.formatted(.number.precision(.fractionLength(0))) },
                     unit: "RPM", color: Phosphor.fg, size: 78)
            HStack(spacing: 12) {
                StatTile(title: "Speed", value: speedMPH.map { String(format: "%.0f", $0) }, unit: "MPH", color: Phosphor.cyan)
                StatTile(title: "Boost", value: boost.map { String(format: "%.1f", $0) }, unit: "PSI", color: Phosphor.pink)
            }

            Panel(title: "Sources") {
                source("OBD-II", obdText, ok: obd.status == .streaming)
                source("GPS", gpsText, ok: gps.connected || phoneGPS.latest != nil)
                source("GoPro", goPro.ready ? (goPro.recording ? "Recording" : "Ready") : "Not connected", ok: goPro.ready,
                       color: goPro.recording ? Phosphor.err : Phosphor.fg)
                if goPro.ready {
                    Toggle("Record video with each run", isOn: $useGoPro).toggleStyle(BracketToggleStyle())
                }
                source("Baro", baroText, ok: recorder.barometer.pressureKPa != nil)
                source("Weather", weatherText, ok: recorder.weatherState == .got)
                Toggle("Fetch the weather for each run", isOn: $fetchWeather)
                    .toggleStyle(BracketToggleStyle())
                    .disabled(recorder.isRecording)
                Text("Sends only your location, rounded to about 1 km, to Open-Meteo.com at the start and end of a run.")
                    .font(.vtCaption).foregroundStyle(Phosphor.mut)
            }

            recordButton

            if let start = recorder.startedAt, recorder.isRecording {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    PromptLine(text: Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond))
                               + "  ·  \(recorder.engineRows) OBD rows  ·  \(recorder.trackPoints) GPS points", color: Phosphor.amber)
                        .monospacedDigit()
                }
            }
            if let e = recorder.error { PromptLine(text: e, color: Phosphor.err) }
            if recorder.saving {
                PromptLine(text: "Saving the run (waiting a few seconds for the weather)...", color: Phosphor.amber)
            } else if let saved = recorder.lastSaved, !recorder.isRecording {
                PromptLine(text: "Saved \(saved.lastPathComponent). Open it from the Runs tab.", color: Phosphor.amber)
            }
            PromptLine(text: "For a dyno pull: floor it in one gear from low RPM to redline on a flat, straight road. "
                       + "A coast with the clutch in from 70 to 30 MPH lets the dyno measure rolling resistance.")
        }
    }

    private var recordButton: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "circle.fill")
                    .font(.system(size: 26))
                Text(recorder.isRecording ? "STOP RUN" : "START RUN")
                    .font(.vt(40, relativeTo: .title))
                    .tracking(2)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .foregroundStyle(recorder.isRecording ? Phosphor.err : Phosphor.fg)
            .glow(recorder.isRecording ? Phosphor.err : Phosphor.fg, radius: 6, opacity: 0.7)
            .background((recorder.isRecording ? Phosphor.err : Phosphor.fg).opacity(0.1))
            .overlay(Rectangle().stroke(recorder.isRecording ? Phosphor.err : Phosphor.fg, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
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
        case .streaming: return obd.name + ", " + String(format: "%.0f/s", obd.rate)
        case .failed(let why): return why
        }
    }

    private var profileText: String {
        guard !editingProfile, let p = VehicleProfiles.profile(for: vehicle) else { return "Weight & drag" }
        var parts: [String] = []
        if let w = p.curbWeightLb { parts.append("\(Int(w + (p.driverCargoLb ?? 0))) lb") }
        if let c = p.dragCoefficient { parts.append(String(format: "Cd %.2f", c)) }
        return parts.isEmpty ? "Weight & drag" : "Weight & drag: " + parts.joined(separator: ", ")
    }

    private var baroText: String {
        guard PhoneBarometer.available else { return "Not on this iPhone" }
        guard let p = recorder.barometer.pressureKPa else { return recorder.isRecording ? "Waiting" : "Starts with the run" }
        return String(format: "%.1f hPa", p * 10)
    }

    private var weatherText: String {
        switch recorder.weatherState {
        case .off: return fetchWeather ? "Fetched with the run" : "Off: the dyno can look it up later"
        case .waitingForFix: return "Waiting for a GPS fix"
        case .fetching: return "Fetching"
        case .failed: return "No signal: the dyno can look it up later"
        case .got:
            guard let w = recorder.weather else { return "Fetched" }
            var parts: [String] = []
            if let t = w.temperatureC { parts.append(String(format: "%.0f °F", t * 9 / 5 + 32)) }
            if let h = w.humidity { parts.append(String(format: "%.0f%%", h)) }
            if let s = w.windSpeedMPH {
                parts.append(String(format: "wind %.0f MPH", s) + (w.windFromDeg.map { String(format: " from %.0f°", $0) } ?? ""))
            }
            return parts.joined(separator: ", ")
        }
    }

    private var gpsText: String {
        if gps.connected { return "\(gps.name), " + String(format: "%.0f Hz", gps.rate) + (gps.battery.map { ", \($0)%" } ?? "") }
        if phoneGPS.latest != nil { return "iPhone, 1 Hz" + (phoneGPS.accuracy.map { String(format: ", ±%.0f m", $0) } ?? "") }
        return "Waiting for a fix"
    }

    private func toggle() {
        editingVehicle = false
        if recorder.isRecording { recorder.stop() } else { recorder.start(vehicle: vehicle, useGoPro: useGoPro, fetchWeather: fetchWeather) }
    }

    private func source(_ title: String, _ detail: String, ok: Bool, color: Color = Phosphor.fg) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ok ? "[ OK ]" : "[ -- ]").foregroundStyle(ok ? color : Phosphor.dim)
            Text(title).foregroundStyle(Phosphor.hi).frame(width: 64, alignment: .leading)
            Text(detail).foregroundStyle(ok ? Phosphor.mut : Phosphor.dim).font(.vtSmall)
                .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
        }
        .font(.vtBody)
        .accessibilityElement(children: .combine)
    }
}
