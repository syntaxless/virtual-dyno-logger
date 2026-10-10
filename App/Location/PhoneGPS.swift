import CoreLocation
import DynoLoggerCore
import Foundation

/// The iPhone's own GPS. It is about 1 Hz, which is enough for the dyno's heading, road grade, altitude and weather
/// lookup, and is the track that gets saved when no external GPS is connected.
@MainActor
final class PhoneGPS: NSObject, ObservableObject {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var latest: TrackPoint?
    @Published private(set) var accuracy: Double?

    var onPoint: ((TrackPoint) -> Void)?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }
}

extension PhoneGPS: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { authorization = manager.authorizationStatus }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for l in locations where l.horizontalAccuracy >= 0 {
                let p = TrackPoint(
                    time: l.timestamp,
                    latitude: l.coordinate.latitude,
                    longitude: l.coordinate.longitude,
                    altitude: l.verticalAccuracy >= 0 ? l.altitude : nil,
                    speed: l.speed >= 0 ? l.speed : nil,
                    course: l.course >= 0 ? l.course : nil
                )
                latest = p
                accuracy = l.horizontalAccuracy
                onPoint?(p)
            }
        }
    }
}
