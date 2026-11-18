import Foundation

/// The OBD-II mode 01 PIDs the dyno log uses.
public enum OBDPID: UInt8, CaseIterable, Sendable {
    case map = 0x0B          // intake manifold absolute pressure, kPa
    case engineRPM = 0x0C
    case vehicleSpeed = 0x0D // km/h
    case throttle = 0x11     // %
    case fuelLevel = 0x2F    // %, fuel tank level
    case baro = 0x33         // kPa
    case ambientTemp = 0x46  // C
    case pedalD = 0x49       // %

    public var dataBytes: Int {
        switch self {
        case .engineRPM: return 2
        default: return 1
        }
    }

    public func decode(_ b: [UInt8]) -> Double {
        let a = Double(b[0])
        switch self {
        case .engineRPM: return (a * 256 + Double(b[1])) / 4
        case .vehicleSpeed, .map, .baro: return a
        case .throttle, .pedalD, .fuelLevel: return a * 100 / 255
        case .ambientTemp: return a - 40
        }
    }
}

/// ELM327 (and clones: OBDLink, Vgate, vLinker) command strings and response decoding. The transport (BLE) sends
/// a command followed by "\r" and collects text until the ">" prompt; everything here works on that text.
public enum ELM327 {
    /// Reset, echo off, linefeeds off, spaces off, headers off, aggressive adaptive timing, automatic protocol.
    public static let setup = ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATAT2", "ATSP0"]

    /// A mode 01 request for up to six PIDs at once ("010C0D49"). CAN cars answer all of them in one reply, which is
    /// what makes 15-25 rows a second possible; older protocols answer only one PID per request.
    public static func request(_ pids: [OBDPID]) -> String {
        "01" + pids.prefix(6).map { String(format: "%02X", $0.rawValue) }.joined()
    }

    /// Requests that list which PIDs the car supports, 32 at a time.
    public static let supportRequests = ["0100", "0120", "0140"]

    /// True for the replies an ELM327 gives when nothing usable came back.
    public static func isError(_ response: String) -> Bool {
        let r = response.uppercased()
        return ["NO DATA", "?", "ERROR", "UNABLE TO CONNECT", "STOPPED", "CAN ERROR", "BUS ERROR"]
            .contains { r.contains($0) }
    }

    /// The messages in a reply, as bytes. A single-frame answer is one hex line per ECU that answered. A multi-frame
    /// (ISO-TP) answer is a byte-count line ("00C") then lines numbered "0:", "1:", ... that join into one message.
    public static func messages(_ response: String) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var multi: [UInt8] = []
        var multiLength: Int?
        for raw in response.split(whereSeparator: \.isNewline) {
            let line = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ">", with: "").uppercased()
            if line.isEmpty || line.hasPrefix("SEARCHING") || line.hasPrefix("BUSINIT") { continue }
            if line.count == 3, let n = Int(line, radix: 16) {
                if !multi.isEmpty { out.append(multi) }
                multi = []
                multiLength = n
            } else if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) == 1 {
                multi += hexBytes(String(line[line.index(after: colon)...]))
            } else {
                let b = hexBytes(line)
                if !b.isEmpty { out.append(b) }
            }
        }
        if !multi.isEmpty {
            if let n = multiLength, multi.count > n { multi = Array(multi.prefix(n)) }
            out.append(multi)
        }
        return out
    }

    /// Decodes a mode 01 reply into values. When several ECUs answer, the first answer for each PID wins.
    public static func parse(_ response: String) -> [OBDPID: Double] {
        var values: [OBDPID: Double] = [:]
        for m in messages(response) {
            guard m.first == 0x41 else { continue }
            var i = 1
            while i < m.count, let pid = OBDPID(rawValue: m[i]), i + pid.dataBytes < m.count {
                if values[pid] == nil { values[pid] = pid.decode(Array(m[(i + 1)...(i + pid.dataBytes)])) }
                i += 1 + pid.dataBytes
            }
        }
        return values
    }

    /// The PIDs a "0100"/"0120"/"0140" reply says are supported.
    public static func supported(_ response: String) -> Set<UInt8> {
        var out = Set<UInt8>()
        for m in messages(response) where m.count >= 6 && m[0] == 0x41 {
            let base = Int(m[1])
            for byte in 0..<4 {
                for bit in 0..<8 where m[2 + byte] & (0x80 >> bit) != 0 {
                    out.insert(UInt8(base + byte * 8 + bit + 1))
                }
            }
        }
        return out
    }

    static func hexBytes(_ s: String) -> [UInt8] {
        guard s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { return [] }
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
