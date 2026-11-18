import DynoLoggerCore
import Foundation

/// The vehicle profiles typed in the app, one per vehicle name, kept in UserDefaults on the phone.
enum VehicleProfiles {
    private static let key = "vehicleProfiles"

    private static func all() -> [String: VehicleProfile] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: VehicleProfile].self, from: d) else { return [:] }
        return m
    }

    /// Profiles are found by name without regard to case or spaces, so "Golf R" and "golfr" share one.
    private static func id(_ vehicle: String) -> String {
        vehicle.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func profile(for vehicle: String) -> VehicleProfile? {
        let p = all()[id(vehicle)]
        return p?.isEmpty == false ? p : nil
    }

    static func save(_ profile: VehicleProfile, for vehicle: String) {
        var m = all()
        m[id(vehicle)] = profile.isEmpty ? nil : profile
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }
}
