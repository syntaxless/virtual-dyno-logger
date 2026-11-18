import CoreBluetooth
import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var ble: BLEManager

    /// What one row shows; in screenshot mode (Demo) the rows are made up, because the Simulator has no Bluetooth.
    private struct Row: Identifiable {
        let id: String
        let name: String
        let kind: DeviceKind
        let rssi: Int
        let connected: Bool
        let device: DiscoveredDevice?
    }

    private var rows: [Row] {
        if Demo.isOn {
            return Demo.devices.map { Row(id: $0.name, name: $0.name, kind: $0.kind, rssi: $0.rssi, connected: $0.connected, device: nil) }
        }
        return ble.devices.values.map { Row(id: $0.id.uuidString, name: $0.name, kind: $0.kind, rssi: $0.rssi, connected: ble.isConnected($0.id), device: $0) }
    }

    private var bluetoothOn: Bool { Demo.isOn || ble.state == .poweredOn }

    var body: some View {
        TerminalScreen(path: "logger/devices", command: "scan --ble", status: ble.scanning || Demo.isOn ? "scanning" : nil) {
            if !bluetoothOn {
                PromptLine(text: ble.state == .unauthorized
                           ? "Dyno Logger isn't allowed to use Bluetooth. Turn it on in Settings > Dyno Logger."
                           : "Turn on Bluetooth to find your OBD-II adapter, GPS and GoPro.", color: Phosphor.amber)
                if ble.state == .unauthorized, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) { Text("Open Settings") }.buttonStyle(BracketButtonStyle())
                }
            } else {
                Button(ble.scanning ? "Stop scan" : "Scan again") { ble.scanning ? ble.stopScan() : ble.startScan() }
                    .buttonStyle(BracketButtonStyle())
                    .disabled(Demo.isOn)
            }

            let all = rows
            if bluetoothOn && all.isEmpty {
                PromptLine(text: "Looking for devices. Turn on the adapter (start the car), the RaceBox and the GoPro.")
            }
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                let list = all.filter { $0.kind == kind }.sorted { $0.rssi > $1.rssi }
                if !list.isEmpty {
                    Panel(title: kind.rawValue) {
                        ForEach(list) { deviceRow($0) }
                        if let f = footer(kind) { Text(f).font(.vtCaption).foregroundStyle(Phosphor.mut) }
                    }
                }
            }
        }
        .onAppear { ble.startScan() }
        .onDisappear { ble.stopScan() }
    }

    @ViewBuilder
    private func deviceRow(_ d: Row) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Text(d.name).foregroundStyle(Phosphor.hi)
                Text(d.connected ? "Connected" : "Signal \(d.rssi) dBm")
                    .font(.vtSmall).foregroundStyle(d.connected ? Phosphor.fg : Phosphor.mut)
            }
            Spacer()
            switch d.kind {
            case .dragy:
                Text("Not supported").font(.vtSmall).foregroundStyle(Phosphor.dim)
            case .other:
                Menu {
                    Button("OBD-II adapter") { if let dev = d.device { ble.connect(dev, as: .obd) } }
                    Button("NMEA GPS receiver") { if let dev = d.device { ble.connect(dev, as: .nmeaGPS) } }
                } label: {
                    Text("[ Use as ]").font(.vtBody).foregroundStyle(Phosphor.fg)
                }
            default:
                Button(d.connected ? "Disconnect" : "Connect") {
                    guard let dev = d.device else { return }
                    d.connected ? ble.disconnect(dev.id) : ble.connect(dev, as: dev.kind)
                }
                .buttonStyle(BracketButtonStyle(color: d.connected ? Phosphor.mut : Phosphor.fg))
            }
        }
        .font(.vtBody)
    }

    private func footer(_ kind: DeviceKind) -> String? {
        switch kind {
        case .dragy:
            return "Dragy's Bluetooth protocol is not public, so this app cannot read it. Export the run from the Dragy app "
                + "and load that CSV into the Virtual Dyno's GPS box."
        case .goPro:
            return "The first time, put the camera in pairing mode: Preferences > Wireless Connections > Connect Device > GoPro Quik."
        case .other:
            return "Devices that don't say what they are. Many cheap OBD-II adapters show up here."
        default:
            return nil
        }
    }
}
