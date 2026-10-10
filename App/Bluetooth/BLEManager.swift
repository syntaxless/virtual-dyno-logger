import CoreBluetooth
import DynoLoggerCore
import Foundation

enum DeviceKind: String, CaseIterable, Codable {
    case obd = "OBD-II adapter"
    case raceBox = "RaceBox"
    case nmeaGPS = "GPS receiver"
    case goPro = "GoPro"
    case dragy = "Dragy"
    case other = "Other"
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var kind: DeviceKind
    var rssi: Int
}

/// The one CBCentralManager. It scans, sorts what it finds by kind, connects, and hands each connected peripheral
/// to the link that speaks its protocol. Devices that were connected before are reconnected on launch.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var devices: [UUID: DiscoveredDevice] = [:]
    @Published private(set) var scanning = false

    let obd = OBDLink()
    let gps = BLEGPSLink()
    let goPro = GoProLink()

    private var central: CBCentralManager!
    private var kinds: [UUID: DeviceKind] = [:]          // what each connecting/connected peripheral is used as
    private static let rememberedKey = "rememberedDevices"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard state == .poweredOn else { return }
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        scanning = false
        central.stopScan()
    }

    func connect(_ device: DiscoveredDevice, as kind: DeviceKind) {
        kinds[device.id] = kind
        devices[device.id]?.kind = kind
        central.connect(device.peripheral)
    }

    func disconnect(_ id: UUID) {
        forget(id)
        if let p = link(for: id)?.peripheral { central.cancelPeripheralConnection(p) }
    }

    func isConnected(_ id: UUID) -> Bool { link(for: id) != nil }

    private func link(for id: UUID) -> PeripheralLink? {
        [obd as PeripheralLink, gps, goPro].first { $0.peripheral?.identifier == id }
    }

    private func linkFor(kind: DeviceKind) -> PeripheralLink? {
        switch kind {
        case .obd, .other: return obd
        case .raceBox, .nmeaGPS: return gps
        case .goPro: return goPro
        case .dragy: return nil
        }
    }

    // Remembered devices (id -> kind), reconnected whenever Bluetooth comes on.
    private var remembered: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.rememberedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.rememberedKey) }
    }

    private func remember(_ id: UUID, _ kind: DeviceKind) {
        var r = remembered
        // One device per role: a new OBD adapter replaces the old one.
        let role = linkFor(kind: kind)
        for (k, v) in r where linkFor(kind: DeviceKind(rawValue: v) ?? .other) === role { r[k] = nil }
        r[id.uuidString] = kind.rawValue
        remembered = r
    }

    private func forget(_ id: UUID) {
        var r = remembered
        r[id.uuidString] = nil
        remembered = r
    }

    private func reconnectRemembered() {
        let r = remembered
        let ids = r.keys.compactMap(UUID.init(uuidString:))
        for p in central.retrievePeripherals(withIdentifiers: ids) {
            guard let raw = r[p.identifier.uuidString], let kind = DeviceKind(rawValue: raw) else { continue }
            kinds[p.identifier] = kind
            central.connect(p)
        }
    }

    static func classify(name: String, services: [CBUUID]) -> DeviceKind? {
        let n = name.lowercased()
        let s = Set(services.map { $0.uuidString.uppercased() })
        if n.hasPrefix("racebox") { return .raceBox }
        if n.contains("dragy") { return .dragy }
        if s.contains(GoPro.advertisedService) || n.hasPrefix("gopro") { return .goPro }
        if !s.isDisjoint(with: OBDLink.knownServices) { return .obd }
        if ["obd", "elm", "vgate", "vlink", "v-link", "vlinker", "veepeak", "obdlink", "konnwei", "carista"]
            .contains(where: n.contains) { return .obd }
        if s.contains(BLEGPSLink.uartService) { return .nmeaGPS }
        return nil
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = central.state
            if central.state == .poweredOn { reconnectRemembered() } else { scanning = false }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let kind = Self.classify(name: name, services: services)
            guard kind != nil || !name.isEmpty else { return }   // unnamed, unknown: not worth listing
            let id = peripheral.identifier
            if devices[id] == nil {
                devices[id] = DiscoveredDevice(id: id, peripheral: peripheral, name: name.isEmpty ? "Unnamed" : name,
                                               kind: kind ?? .other, rssi: RSSI.intValue)
            } else {
                devices[id]?.rssi = RSSI.intValue
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let kind = kinds[peripheral.identifier] ?? .other
            guard let link = linkFor(kind: kind) else { central.cancelPeripheralConnection(peripheral); return }
            if let old = link.peripheral, old.identifier != peripheral.identifier { central.cancelPeripheralConnection(old) }
            remember(peripheral.identifier, kind)
            if devices[peripheral.identifier] == nil {   // reconnected at launch: connected devices do not advertise
                devices[peripheral.identifier] = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                                                  name: peripheral.name ?? kind.rawValue, kind: kind, rssi: 0)
            }
            link.attach(peripheral, kind: kind)
            objectWillChange.send()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { linkFor(kind: kinds[peripheral.identifier] ?? .other)?.failed(error) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            link(for: id)?.detach()
            objectWillChange.send()
            // Dropped rather than disconnected on purpose: keep trying (a pending connect never times out).
            if remembered[id.uuidString] != nil { central.connect(peripheral) }
        }
    }
}

/// What BLEManager needs from each protocol link.
@MainActor
protocol PeripheralLink: AnyObject {
    var peripheral: CBPeripheral? { get }
    func attach(_ peripheral: CBPeripheral, kind: DeviceKind)
    func detach()
    func failed(_ error: Error?)
}
