import CoreBluetooth
import DynoLoggerCore
import Foundation

/// A GoPro (HERO9 or later) over Open GoPro BLE. On connect it sets the camera's clock to the phone's, so the video's
/// times match the logs, and keeps the camera awake; recording starts and stops with the session.
/// The first connection needs the camera in pairing mode (Preferences > Wireless Connections > Connect Device > GoPro Quik).
@MainActor
final class GoProLink: NSObject, ObservableObject, PeripheralLink {
    @Published private(set) var ready = false
    @Published private(set) var name = ""
    @Published private(set) var recording = false
    @Published private(set) var problem: String?

    private(set) var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var settings: CBCharacteristic?
    private var keepAlive: Timer?
    private var requested: Bool?

    func attach(_ peripheral: CBPeripheral, kind: DeviceKind) {
        detach()
        self.peripheral = peripheral
        name = peripheral.name ?? "GoPro"
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: GoPro.advertisedService)])
    }

    func detach() {
        keepAlive?.invalidate()
        keepAlive = nil
        peripheral = nil
        command = nil
        settings = nil
        ready = false
        recording = false
    }

    func failed(_ error: Error?) {
        problem = error?.localizedDescription ?? "Could not connect"
    }

    func setRecording(_ on: Bool) {
        requested = on
        if Demo.isOn, peripheral == nil { recording = on; return }
        write(GoPro.shutter(on), to: command)
    }

    private func write(_ bytes: [UInt8], to c: CBCharacteristic?) {
        guard let p = peripheral, let c else { return }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    private func becameReady() {
        ready = true
        problem = nil
        write(GoPro.setDateTime(Date()), to: command)
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write(GoPro.keepAlive, to: self?.settings) }
        }
    }

    private func response(_ bytes: [UInt8]) {
        // A shutter reply says whether the camera took the command; a refusal usually means it is busy or has no card.
        guard bytes.count >= 3, bytes[1] == 0x01 else { return }
        if bytes[2] == 0, let r = requested { recording = r } else if bytes[2] != 0 { problem = "The camera refused to start or stop recording." }
    }
}

extension GoProLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first else { problem = "This is not an Open GoPro camera."; return }
            peripheral.discoverCharacteristics(
                [GoPro.commandUUID, GoPro.commandResponseUUID, GoPro.settingsUUID].map { CBUUID(string: $0) }, for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                switch c.uuid.uuidString.uppercased() {
                case GoPro.commandUUID: command = c
                case GoPro.settingsUUID: settings = c
                case GoPro.commandResponseUUID: peripheral.setNotifyValue(true, for: c)   // pairs on first use
                default: break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error { problem = "Pairing failed: \(error.localizedDescription). Put the camera in pairing mode and try again." }
            else if command != nil { becameReady() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let v = characteristic.value { response([UInt8](v)) }
        }
    }
}

// Screenshot mode (see Demo): a camera that is ready and follows the record button.
extension GoProLink {
    func demoConnect() {
        name = "GoPro HERO12"
        ready = true
    }
}
