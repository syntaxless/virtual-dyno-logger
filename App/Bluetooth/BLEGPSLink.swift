import CoreBluetooth
import DynoLoggerCore
import Foundation

/// An external GPS over the Nordic UART service: a RaceBox (binary data messages, 25 Hz) or any receiver that sends
/// NMEA text. External GPS is worth having: the phone gives about 1 Hz, and the dyno uses GPS speed for the power
/// curve only when the track is 5 Hz or faster.
@MainActor
final class BLEGPSLink: NSObject, ObservableObject, PeripheralLink {
    static let uartService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let uartTX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"   // device -> phone (notify)

    @Published private(set) var connected = false
    @Published private(set) var name = ""
    @Published private(set) var kind: DeviceKind = .nmeaGPS
    @Published private(set) var latest: TrackPoint?
    @Published private(set) var rate: Double = 0
    @Published private(set) var battery: Int?
    @Published private(set) var problem: String?

    var onPoint: ((TrackPoint) -> Void)?
    private(set) var peripheral: CBPeripheral?
    private var raceBox = RaceBoxDecoder()
    private var nmea = NMEAAssembler()
    private var window: [Date] = []

    func attach(_ peripheral: CBPeripheral, kind: DeviceKind) {
        detach()
        self.peripheral = peripheral
        self.kind = kind
        name = peripheral.name ?? kind.rawValue
        raceBox = RaceBoxDecoder()
        nmea = NMEAAssembler()
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: Self.uartService)])
    }

    func detach() {
        peripheral = nil
        connected = false
        latest = nil
        rate = 0
        battery = nil
    }

    func failed(_ error: Error?) {
        problem = error?.localizedDescription ?? "Could not connect"
    }

    private func received(_ data: Data) {
        let points: [TrackPoint]
        if kind == .raceBox {
            let readings = raceBox.feed(data)
            if let b = readings.last?.batteryPercent { battery = b }
            points = readings.map(\.point)
        } else {
            points = nmea.feed(data)
        }
        guard !points.isEmpty else { return }
        let now = Date()
        for p in points {
            window.append(now)
            onPoint?(p)
        }
        window.removeAll { now.timeIntervalSince($0) > 2 }
        rate = Double(window.count) / 2
        latest = points.last
    }
}

extension BLEGPSLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first(where: { $0.uuid == CBUUID(string: Self.uartService) }) else {
                problem = "This device has no Nordic UART service."
                return
            }
            peripheral.discoverCharacteristics([CBUUID(string: Self.uartTX)], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let tx = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Self.uartTX) }) else { return }
            peripheral.setNotifyValue(true, for: tx)
            connected = true
            problem = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let v = characteristic.value { received(v) }
        }
    }
}
