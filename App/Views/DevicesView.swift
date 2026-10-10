import SwiftUI

struct DevicesView: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        NavigationStack {
            List {
                if ble.state != .poweredOn {
                    Text("Turn on Bluetooth and allow Dyno Logger to use it in Settings.").foregroundStyle(.secondary)
                }
                ForEach(DeviceKind.allCases, id: \.self) { kind in
                    let list = ble.devices.values.filter { $0.kind == kind }.sorted { $0.rssi > $1.rssi }
                    if !list.isEmpty {
                        Section {
                            ForEach(list) { d in deviceRow(d) }
                        } header: {
                            Text(kind.rawValue)
                        } footer: {
                            if let f = footer(kind) { Text(f) }
                        }
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                Button(ble.scanning ? "Stop" : "Scan") { ble.scanning ? ble.stopScan() : ble.startScan() }
                    .disabled(ble.state != .poweredOn)
            }
            .onAppear { ble.startScan() }
            .onDisappear { ble.stopScan() }
        }
    }

    @ViewBuilder
    private func deviceRow(_ d: DiscoveredDevice) -> some View {
        let connected = ble.isConnected(d.id)
        HStack {
            VStack(alignment: .leading) {
                Text(d.name)
                Text("Signal \(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch d.kind {
            case .dragy:
                Text("Not supported").foregroundStyle(.secondary)
            case .other:
                Menu("Use as") {
                    Button("OBD-II adapter") { ble.connect(d, as: .obd) }
                    Button("NMEA GPS receiver") { ble.connect(d, as: .nmeaGPS) }
                }
            default:
                Button(connected ? "Disconnect" : "Connect") {
                    connected ? ble.disconnect(d.id) : ble.connect(d, as: d.kind)
                }
                .buttonStyle(.bordered)
            }
        }
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
