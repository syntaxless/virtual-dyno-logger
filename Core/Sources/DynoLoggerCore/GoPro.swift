import Foundation

/// Open GoPro BLE (HERO9 and later): UUIDs and the few commands this app sends. Every message written here fits in
/// one BLE packet, so it is the Open GoPro "general" 5-bit header (the payload length) followed by the payload.
/// https://gopro.github.io/OpenGoPro/ble/
public enum GoPro {
    /// Advertised service the camera uses while it is paired or in pairing mode.
    public static let advertisedService = "FEA6"

    public static func uuid(_ short: String) -> String { "B5F9\(short)-AA8D-11E3-9046-0002A5D5C51B" }
    public static let commandUUID = uuid("0072")
    public static let commandResponseUUID = uuid("0073")
    public static let settingsUUID = uuid("0074")
    public static let settingsResponseUUID = uuid("0075")
    public static let queryUUID = uuid("0076")
    public static let queryResponseUUID = uuid("0077")

    /// Command 0x01 "Set Shutter": starts or stops recording in the current mode.
    public static func shutter(_ on: Bool) -> [UInt8] { [0x03, 0x01, 0x01, on ? 0x01 : 0x00] }

    /// Setting 0x5B (keep alive), written every few seconds so the camera does not sleep while it waits.
    public static let keepAlive: [UInt8] = [0x03, 0x5B, 0x01, 0x42]

    /// Command 0x0D "Set Date Time", in UTC, so the camera's file times line up with the logs.
    public static func setDateTime(_ date: Date) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = c.year!
        return [0x09, 0x0D, 0x07, UInt8(y >> 8), UInt8(y & 0xFF),
                UInt8(c.month!), UInt8(c.day!), UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!)]
    }

    /// A command response is [length, command id, status]; status 0 means it worked.
    public static func responseOK(_ bytes: [UInt8], command: UInt8) -> Bool? {
        guard bytes.count >= 3, bytes[1] == command else { return nil }
        return bytes[2] == 0
    }
}
