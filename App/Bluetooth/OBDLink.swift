import CoreBluetooth
import DynoLoggerCore
import Foundation

/// One poll of the ECU: when the reply came back and what it held.
struct OBDReading {
    let date: Date
    let values: [OBDPID: Double]
}

/// An ELM327-compatible BLE adapter. Sends text commands, waits for the ">" prompt, and once set up polls RPM, speed,
/// pedal and manifold pressure as fast as the car answers (ambient temperature and pressure every couple of seconds).
@MainActor
final class OBDLink: NSObject, ObservableObject, PeripheralLink {
    enum Status: Equatable {
        case disconnected, connecting, initializing, streaming
        case failed(String)
    }

    /// Services BLE OBD adapters use for their serial port.
    static let knownServices: Set<String> = ["FFF0", "FFE0", "18F0", "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"]

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var name = ""
    @Published private(set) var latest: [OBDPID: Double] = [:]
    @Published private(set) var rate: Double = 0          // polls per second
    @Published private(set) var pedalSource: PedalSource = .pedal

    var onReading: ((OBDReading) -> Void)?
    private(set) var peripheral: CBPeripheral?

    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var rx = ""
    private var pending: (id: Int, continuation: CheckedContinuation<String, Error>)?
    private var nextID = 0
    private var poller: Task<Void, Never>?
    private var servicesLeft = 0

    struct Timeout: Error {}

    func attach(_ peripheral: CBPeripheral, kind: DeviceKind) {
        detach()
        self.peripheral = peripheral
        name = peripheral.name ?? "OBD-II adapter"
        status = .connecting
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func detach() {
        poller?.cancel()
        poller = nil
        pending?.continuation.resume(throwing: CancellationError())
        pending = nil
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        latest = [:]
        rate = 0
        status = .disconnected
    }

    func failed(_ error: Error?) {
        status = .failed(error?.localizedDescription ?? "Could not connect")
    }

    // MARK: Commands

    /// Sends one command and returns the text before the ">" prompt.
    func send(_ command: String, timeout: Double) async throws -> String {
        guard let p = peripheral, let w = writeChar else { throw CancellationError() }
        pending?.continuation.resume(throwing: CancellationError())
        rx = ""
        nextID += 1
        let id = nextID
        let data = Data((command + "\r").utf8)
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let chunk = max(20, p.maximumWriteValueLength(for: type))
        return try await withCheckedThrowingContinuation { c in
            pending = (id, c)
            var i = 0
            while i < data.count {
                p.writeValue(data.subdata(in: i..<min(data.count, i + chunk)), for: w, type: type)
                i += chunk
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let pend = self.pending, pend.id == id else { return }
                self.pending = nil
                pend.continuation.resume(throwing: Timeout())
            }
        }
    }

    private func received(_ data: Data) {
        rx += String(decoding: data, as: UTF8.self)
        guard let prompt = rx.firstIndex(of: ">") else { return }
        let reply = String(rx[..<prompt])
        rx = String(rx[rx.index(after: prompt)...])
        if let pend = pending {
            pending = nil
            pend.continuation.resume(returning: reply)
        }
    }

    // MARK: Polling

    private func start() {
        poller?.cancel()
        poller = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        status = .initializing
        do {
            for cmd in ELM327.setup {
                _ = try await send(cmd, timeout: cmd == "ATZ" ? 3 : 1.5)
            }
            // The first request makes the adapter search for the car's protocol, which can take several seconds.
            var supported = Set<UInt8>()
            for req in ELM327.supportRequests {
                if let r = try? await send(req, timeout: 10), !ELM327.isError(r) { supported.formUnion(ELM327.supported(r)) }
            }
            guard supported.contains(OBDPID.engineRPM.rawValue) || supported.isEmpty else {
                status = .failed("The car does not report RPM over OBD-II.")
                return
            }
            let has = { (p: OBDPID) in supported.isEmpty || supported.contains(p.rawValue) }
            pedalSource = supported.contains(OBDPID.pedalD.rawValue) ? .pedal : .throttle
            var fast: [OBDPID] = [.engineRPM, .vehicleSpeed, pedalSource == .pedal ? .pedalD : .throttle]
            if has(.map) { fast.append(.map) }
            let slow = [OBDPID.baro, .ambientTemp, .fuelLevel].filter { supported.contains($0.rawValue) }

            // CAN cars answer several PIDs per request; older protocols need one request per PID.
            let probe = ELM327.parse(try await send(ELM327.request(fast), timeout: 2))
            let multi = probe.count == fast.count
            status = .streaming

            var cycle = 0, failures = 0
            var window: [Date] = []
            while !Task.isCancelled {
                let sent = Date()
                var values: [OBDPID: Double] = [:]
                do {
                    if multi {
                        values = ELM327.parse(try await send(ELM327.request(fast), timeout: 1))
                    } else {
                        for p in fast { values.merge(ELM327.parse(try await send(ELM327.request([p]), timeout: 1))) { a, _ in a } }
                    }
                    if cycle % 30 == 0 {
                        for p in slow { values.merge(ELM327.parse(try await send(ELM327.request([p]), timeout: 1))) { a, _ in a } }
                    }
                    failures = 0
                } catch is Timeout {
                    failures += 1
                    if failures >= 10 { status = .failed("The adapter stopped answering."); return }
                    continue
                }
                let now = Date()
                // Time the reading at the middle of the round trip, which is the closest guess to when the ECU sampled it.
                let reading = OBDReading(date: sent.addingTimeInterval(now.timeIntervalSince(sent) / 2), values: values)
                latest.merge(values) { _, b in b }
                window.append(now)
                window.removeAll { now.timeIntervalSince($0) > 2 }
                rate = Double(window.count) / 2
                onReading?(reading)
                cycle += 1
            }
        } catch is CancellationError {
        } catch {
            status = .failed("Setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: Characteristics

    /// Chooses the serial port once every service's characteristics are known: an adapter's well-known service first,
    /// else the first vendor service with a notify and a write characteristic.
    private func choosePort(_ services: [CBService]) {
        let standard: Set<String> = ["1800", "1801", "180A", "180F"]
        let vendor = services.filter { !standard.contains($0.uuid.uuidString.uppercased()) }
        let ordered = vendor.filter { Self.knownServices.contains($0.uuid.uuidString.uppercased()) }
            + vendor.filter { !Self.knownServices.contains($0.uuid.uuidString.uppercased()) }
        for service in ordered {
            let chars = service.characteristics ?? []
            let notify = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let write = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            guard let n = notify, let w = write else { continue }
            notifyChar = n
            writeChar = w
            peripheral?.setNotifyValue(true, for: n)
            return
        }
        status = .failed("This device has no serial port an OBD-II app can use.")
    }
}

extension OBDLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = peripheral.services ?? []
            servicesLeft = services.count
            if services.isEmpty { status = .failed("This device has no serial port an OBD-II app can use.") }
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            servicesLeft -= 1
            if servicesLeft == 0 { choosePort(peripheral.services ?? []) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == notifyChar else { return }
            if let error { status = .failed(error.localizedDescription) } else if poller == nil { start() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic == notifyChar, let v = characteristic.value else { return }
            received(v)
        }
    }
}

// Screenshot mode (see Demo): simulated readings, as if an adapter were streaming.
extension OBDLink {
    func demoFeed(_ r: OBDReading, rate: Double) {
        name = "OBDLink CX"
        status = .streaming
        latest = r.values
        self.rate = rate
        onReading?(r)
    }
}
