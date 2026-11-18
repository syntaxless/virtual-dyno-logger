import CoreMotion
import Foundation

/// The iPhone's barometer (CMAltimeter). It gives air pressure for the dyno's density altitude when the car does not
/// report baro, and a relative altitude in steps of about 10 cm, which is a much cleaner road grade than GPS elevation.
/// It reads cabin pressure, which with the windows up is within a few hundredths of a psi of the air outside; an open
/// window at speed can pull it down, which is why the car's own sensor wins when there is one.
@MainActor
final class PhoneBarometer: ObservableObject {
    @Published private(set) var pressureKPa: Double?
    /// Metres since `start()` was last called.
    @Published private(set) var relativeAltitude: Double?

    static var available: Bool { CMAltimeter.isRelativeAltitudeAvailable() }
    private let altimeter = CMAltimeter()
    private var running = false

    /// Starting again resets the relative altitude to zero, so each run's altitude starts at 0 m.
    func start() {
        guard Self.available else { return }
        if running { altimeter.stopRelativeAltitudeUpdates() }
        running = true
        relativeAltitude = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                self?.pressureKPa = data.pressure.doubleValue
                self?.relativeAltitude = data.relativeAltitude.doubleValue
            }
        }
    }

    func stop() {
        guard running else { return }
        altimeter.stopRelativeAltitudeUpdates()
        running = false
    }
}
