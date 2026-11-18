import DynoLoggerCore
import Foundation

/// Fetches Open-Meteo's current weather for where the phone is. This is the app's only network call. It sends the
/// position rounded to about 1 km (`OpenMeteo.currentURL`) and nothing else: no cookies, no cache, no identifiers.
/// With no signal it gives up after a few seconds and the run is saved without weather; the dyno can still look it up
/// later from the GPX track's time and place.
enum WeatherService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 8
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func current(latitude: Double, longitude: Double) async -> WeatherSnapshot? {
        guard let url = OpenMeteo.currentURL(latitude: latitude, longitude: longitude) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try OpenMeteo.parseCurrent(data)
        } catch {
            return nil
        }
    }
}
