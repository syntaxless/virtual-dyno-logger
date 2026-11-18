import Foundation

/// The weather where the phone was, from Open-Meteo's current conditions (a 15-minute model value, not a station
/// reading). The app fetches one when a run starts and one when it stops, and writes them into the engine log as
/// their own columns, so the Virtual Dyno has humidity and wind even when it is used offline. A car sensor (ambient
/// temperature, barometric pressure) still wins over these in the dyno.
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    /// When the model value is valid (Open-Meteo's `current.time`, UTC).
    public var time: Date
    /// The rounded position that was sent (see `OpenMeteo.rounded`).
    public var latitude: Double
    public var longitude: Double
    public var temperatureC: Double?
    public var humidity: Double?
    /// 10 m wind, MPH.
    public var windSpeedMPH: Double?
    /// Where the wind blows from, degrees from true north.
    public var windFromDeg: Double?
    /// Sea-level pressure, hPa (the dyno reduces it to the pull's altitude).
    public var pressureMSLhPa: Double?

    public init(time: Date, latitude: Double, longitude: Double, temperatureC: Double? = nil, humidity: Double? = nil,
                windSpeedMPH: Double? = nil, windFromDeg: Double? = nil, pressureMSLhPa: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.temperatureC = temperatureC
        self.humidity = humidity
        self.windSpeedMPH = windSpeedMPH
        self.windFromDeg = windFromDeg
        self.pressureMSLhPa = pressureMSLhPa
    }
}

/// Open-Meteo (https://open-meteo.com, CC BY 4.0): free, no key or account. Only the position rounded to 0.01 degree
/// (about 1 km) is sent, the same as the dyno page sends, and nothing that identifies the person or the phone.
public enum OpenMeteo {
    public static let variables = "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,pressure_msl"

    /// 0.01 degree is about 1.1 km of latitude: enough for weather, too coarse to place a house.
    public static func rounded(_ x: Double) -> Double {
        (x * 100).rounded() / 100
    }

    public static func currentURL(latitude: Double, longitude: Double) -> URL? {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", rounded(latitude))),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", rounded(longitude))),
            URLQueryItem(name: "current", value: variables),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return c.url
    }

    public enum ParseError: Error, Equatable {
        case notWeather
    }

    /// Reads the `current` block of an answer to `currentURL`. Values that are missing or not numbers are left nil.
    public static func parseCurrent(_ data: Data) throws -> WeatherSnapshot {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = j["current"] as? [String: Any],
              let ts = cur["time"] as? String,
              let time = gmt.date(from: ts) ?? gmtSeconds.date(from: ts),
              let lat = (j["latitude"] as? NSNumber)?.doubleValue,
              let lon = (j["longitude"] as? NSNumber)?.doubleValue
        else { throw ParseError.notWeather }
        func num(_ k: String) -> Double? {
            guard let n = cur[k] as? NSNumber else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        let snap = WeatherSnapshot(time: time, latitude: rounded(lat), longitude: rounded(lon),
                                   temperatureC: num("temperature_2m"), humidity: num("relative_humidity_2m"),
                                   windSpeedMPH: num("wind_speed_10m"), windFromDeg: num("wind_direction_10m"),
                                   pressureMSLhPa: num("pressure_msl"))
        guard snap.humidity != nil || snap.windSpeedMPH != nil || snap.temperatureC != nil else { throw ParseError.notWeather }
        return snap
    }

    // Open-Meteo writes times without a zone ("2026-11-18T06:15"); with timezone=GMT they are UTC.
    private static let gmt: DateFormatter = fmt("yyyy-MM-dd'T'HH:mm")
    private static let gmtSeconds: DateFormatter = fmt("yyyy-MM-dd'T'HH:mm:ss")
    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "UTC")
        d.dateFormat = f
        return d
    }
}
