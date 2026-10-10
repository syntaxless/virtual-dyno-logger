import Foundation

/// RaceBox Mini / Mini S / Micro: 25 Hz GPS over BLE, Nordic UART service, "RaceBox Data Message" packets
/// (UBX-style framing, class 0xFF, id 0x01, 80-byte payload), per RaceBox's published BLE protocol document.
/// The offsets below are from that document; check them against a real unit before relying on them.
public struct RaceBoxDecoder {
    public struct Reading: Equatable, Sendable {
        public var point: TrackPoint
        public var fixStatus: UInt8
        /// Longitudinal, lateral and vertical acceleration in g.
        public var gForce: (x: Double, y: Double, z: Double)
        public var batteryPercent: Int

        public static func == (a: Reading, b: Reading) -> Bool {
            a.point == b.point && a.fixStatus == b.fixStatus && a.batteryPercent == b.batteryPercent
                && a.gForce.x == b.gForce.x && a.gForce.y == b.gForce.y && a.gForce.z == b.gForce.z
        }
    }

    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds notification bytes; returns every complete data message with a 2D or 3D fix.
    public mutating func feed(_ data: Data) -> [Reading] {
        buffer += data
        var out: [Reading] = []
        while true {
            guard let start = buffer.firstIndex(of: 0xB5) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= 8 else { break }
            guard buffer[1] == 0x62 else { buffer.removeFirst(); continue }
            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            guard length <= 512 else { buffer.removeFirst(); continue }
            guard buffer.count >= 8 + length else { break }
            let packet = Array(buffer[0..<(8 + length)])
            if Self.checksumOK(packet), packet[2] == 0xFF, packet[3] == 0x01, length == 80,
               let r = Self.decode(Array(packet[6..<(6 + length)])) {
                out.append(r)
            }
            buffer.removeFirst(8 + length)
        }
        return out
    }

    static func checksumOK(_ p: [UInt8]) -> Bool {
        var a: UInt8 = 0, b: UInt8 = 0
        for byte in p[2..<(p.count - 2)] {
            a = a &+ byte
            b = b &+ a
        }
        return a == p[p.count - 2] && b == p[p.count - 1]
    }

    /// Decodes an 80-byte data message payload. Nil when there is no 2D/3D fix or the date is not valid.
    public static func decode(_ p: [UInt8]) -> Reading? {
        guard p.count >= 80 else { return nil }
        func u16(_ o: Int) -> Int { Int(p[o]) | Int(p[o + 1]) << 8 }
        func i16(_ o: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(o)))) }
        func i32(_ o: Int) -> Int {
            Int(Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24))
        }
        let fix = p[20]
        guard fix >= 2, p[21] & 0x01 != 0 else { return nil }
        var c = DateComponents()
        c.timeZone = TimeZone(identifier: "UTC")
        c.year = u16(4)
        c.month = Int(p[6])
        c.day = Int(p[7])
        c.hour = Int(p[8])
        c.minute = Int(p[9])
        c.second = Int(p[10])
        guard c.year! >= 2020, let whole = Calendar(identifier: .gregorian).date(from: c) else { return nil }
        let time = whole.addingTimeInterval(Double(i32(16)) / 1e9)
        let point = TrackPoint(
            time: time,
            latitude: Double(i32(28)) / 1e7,
            longitude: Double(i32(24)) / 1e7,
            altitude: fix == 3 ? Double(i32(36)) / 1000 : nil,
            speed: Double(i32(48)) / 1000,
            course: Double(i32(52)) / 1e5,
            satellites: Int(p[23]),
            hdop: Double(u16(64)) / 100   // PDOP; the closest thing the message has
        )
        return Reading(point: point, fixStatus: fix,
                       gForce: (Double(i16(68)) / 1000, Double(i16(70)) / 1000, Double(i16(72)) / 1000),
                       batteryPercent: Int(p[67] & 0x7F))
    }
}
