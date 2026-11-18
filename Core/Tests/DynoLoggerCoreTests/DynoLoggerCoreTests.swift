import XCTest
@testable import DynoLoggerCore

final class EngineLogTests: XCTestCase {
    func testCobbStyleCSV() {
        let samples = [
            EngineSample(time: 0, rpm: 2400, speedKmh: 50, pedalRaw: 16.1, mapKPa: 100, baroKPa: 98, ambientC: 21),
            EngineSample(time: 0.05, rpm: 2450.5, speedKmh: 51, pedalRaw: 80, mapKPa: 180),
            EngineSample(time: 0.0501, rpm: 9999, speedKmh: 99),   // same millisecond: dropped, like the dyno does
            EngineSample(time: 0.1, rpm: 2500, speedKmh: 52),
        ]
        XCTAssertEqual(EngineLog.csv(samples), """
        Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Accel. Pedal Position (%),Ambient Air Temp (F),Ambient Pressure (psi),Boost Press. (psi)
        0,2400,50,16.1,69.8,14.21,0.3
        50,2451,51,80.0,69.8,14.21,11.9
        100,2500,52,,69.8,14.21,

        """)
    }

    func testOnlyColumnsWithDataAreWritten() {
        let csv = EngineLog.csv([EngineSample(time: 0, rpm: 900, speedKmh: 0, pedalRaw: 20)], pedalSource: .throttle)
        XCTAssertEqual(csv, "Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Throttle Position (%)\n0,900,0,20.0\n")
    }

    func testPedalScaledToFullTravel() {
        let raw = Array(repeating: 15.3, count: 200) + Array(repeating: 81.2, count: 100)
        let s = PedalScale(raw)
        XCTAssertEqual(s.apply(15.3), 0, accuracy: 1e-9)
        XCTAssertEqual(s.apply(81.2), 100, accuracy: 1e-9)
        XCTAssertEqual(PedalScale(Array(repeating: 15, count: 50) + [30]), PedalScale(low: 0, high: 100))
    }
}

final class GPXTests: XCTestCase {
    func testTrackPoint() {
        let t = Date(timeIntervalSince1970: 1_791_651_903.125)   // 2026-10-10T17:05:03.125Z
        let gpx = GPX.document([
            TrackPoint(time: t, latitude: 39.7392358, longitude: -104.990251, altitude: 1609.3, speed: 26.8224,
                       course: 92.5, satellites: 14, hdop: 0.7),
            TrackPoint(time: t, latitude: 0, longitude: 0),   // same time: dropped
        ], name: "Golf R & co")
        XCTAssertTrue(gpx.contains("<gpx version=\"1.0\""))
        XCTAssertTrue(gpx.contains("<name>Golf R &amp; co</name>"))
        XCTAssertTrue(gpx.contains("<trkpt lat=\"39.7392358\" lon=\"-104.9902510\"><ele>1609.30</ele>"
            + "<time>2026-10-10T17:05:03.125Z</time><course>92.5</course><speed>26.822</speed><sat>14</sat>"
            + "<hdop>0.70</hdop></trkpt>"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt").count, 2)
    }
}

final class ELM327Tests: XCTestCase {
    func testSingleFrame() {
        let v = ELM327.parse("410C1AF80D32\r\r>")
        XCTAssertEqual(v[.engineRPM], 1726)
        XCTAssertEqual(v[.vehicleSpeed], 50)
    }

    func testCRLF() {
        XCTAssertEqual(ELM327.parse("410C1AF8\r\n>")[.engineRPM], 1726)
    }

    func testSpacesAndTwoECUs() {
        let v = ELM327.parse("41 0C 1A F8\r41 0C 00 00\r>")
        XCTAssertEqual(v[.engineRPM], 1726)
    }

    func testMultiFrame() {
        let v = ELM327.parse("00A\r0:410C1AF80D32\r1:49CC0B96000000\r\r>")
        XCTAssertEqual(v[.engineRPM], 1726)
        XCTAssertEqual(v[.vehicleSpeed], 50)
        XCTAssertEqual(v[.pedalD]!, 80, accuracy: 1e-9)
        XCTAssertEqual(v[.map], 150)
    }

    func testErrors() {
        XCTAssertTrue(ELM327.isError("NO DATA\r>"))
        XCTAssertTrue(ELM327.parse("SEARCHING...\rUNABLE TO CONNECT\r>").isEmpty)
    }

    func testRequestAndSupport() {
        XCTAssertEqual(ELM327.request([.engineRPM, .vehicleSpeed, .pedalD, .map]), "010C0D490B")
        let s = ELM327.supported("4100BE3FB813\r>")
        XCTAssertTrue([0x0B, 0x0C, 0x0D, 0x11].allSatisfy(s.contains))
        XCTAssertFalse(s.contains(0x02))
    }
}

final class NMEATests: XCTestCase {
    func testRMCWithGGA() {
        var n = NMEAAssembler()
        let text = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n"
            + "$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A\r\n"
        let half = text.index(text.startIndex, offsetBy: 40)
        XCTAssertTrue(n.feed(Data(text[..<half].utf8)).isEmpty)
        let pts = n.feed(Data(text[half...].utf8))
        XCTAssertEqual(pts.count, 1)
        guard let p = pts.first else { return }
        XCTAssertEqual(p.latitude, 48.1173, accuracy: 1e-6)
        XCTAssertEqual(p.longitude, 11.516666, accuracy: 1e-5)
        XCTAssertEqual(p.speed!, 22.4 * 1852 / 3600, accuracy: 1e-9)
        XCTAssertEqual(p.altitude, 545.4)
        XCTAssertEqual(p.satellites, 8)
    }

    func testBadChecksumIgnored() {
        var n = NMEAAssembler()
        XCTAssertTrue(n.feed(Data("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*00\n".utf8)).isEmpty)
    }
}

final class RaceBoxTests: XCTestCase {
    func testDataMessage() {
        var p = [UInt8](repeating: 0, count: 80)
        func put(_ v: Int, at o: Int, bytes: Int) { for i in 0..<bytes { p[o + i] = UInt8((v >> (8 * i)) & 0xFF) } }
        put(2026, at: 4, bytes: 2)
        p[6] = 10; p[7] = 10; p[8] = 17; p[9] = 5; p[10] = 3
        put(125_000_000, at: 16, bytes: 4)
        p[20] = 3; p[21] = 1; p[23] = 12
        put(-1_049_902_510, at: 24, bytes: 4)
        put(397_392_358, at: 28, bytes: 4)
        put(1_609_300, at: 36, bytes: 4)
        put(26_822, at: 48, bytes: 4)
        put(9_250_000, at: 52, bytes: 4)
        put(-1000, at: 68, bytes: 2)
        p[67] = 87
        var packet: [UInt8] = [0xB5, 0x62, 0xFF, 0x01, 80, 0] + p
        var a: UInt8 = 0, b: UInt8 = 0
        for x in packet[2...] { a = a &+ x; b = b &+ a }
        packet += [a, b]

        var d = RaceBoxDecoder()
        XCTAssertTrue(d.feed(Data([0x00, 0x13] + packet[..<30])).isEmpty)
        let r = d.feed(Data(packet[30...]))
        XCTAssertEqual(r.count, 1)
        guard !r.isEmpty else { return }
        XCTAssertEqual(r[0].point.time, Date(timeIntervalSince1970: 1_791_651_903.125))
        XCTAssertEqual(r[0].point.latitude, 39.7392358, accuracy: 1e-9)
        XCTAssertEqual(r[0].point.longitude, -104.990251, accuracy: 1e-9)
        XCTAssertEqual(r[0].point.altitude!, 1609.3, accuracy: 1e-9)
        XCTAssertEqual(r[0].point.speed!, 26.822, accuracy: 1e-9)
        XCTAssertEqual(r[0].point.course!, 92.5, accuracy: 1e-9)
        XCTAssertEqual(r[0].gForce.x, -1, accuracy: 1e-9)
        XCTAssertEqual(r[0].batteryPercent, 87)
    }
}

final class GoProTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(GoPro.shutter(true), [0x03, 0x01, 0x01, 0x01])
        XCTAssertEqual(GoPro.setDateTime(Date(timeIntervalSince1970: 1_791_651_903)),
                       [0x09, 0x0D, 0x07, 0x07, 0xEA, 10, 10, 17, 5, 3])
        XCTAssertEqual(GoPro.responseOK([0x02, 0x01, 0x00], command: 0x01), true)
        XCTAssertEqual(GoPro.commandUUID, "B5F90072-AA8D-11E3-9046-0002A5D5C51B")
    }
}

final class SessionTests: XCTestCase {
    func testBaseName() {
        let d = Date(timeIntervalSince1970: 1_791_651_903)
        XCTAssertEqual(SessionFiles.baseName(vehicle: "Golf R", start: d, timeZone: TimeZone(identifier: "UTC")!),
                       "GolfR_2026-10-10_170503")
    }
}

final class PhoneSensorTests: XCTestCase {
    func testPhoneBarometerFillsAmbientPressureOnlyWhenTheCarHasNone() {
        let noCarBaro = EngineLog.csv([
            EngineSample(time: 0, rpm: 2400, speedKmh: 50, mapKPa: 180, phoneBaroKPa: 98.5),
            EngineSample(time: 0.05, rpm: 2450, speedKmh: 51, mapKPa: 190),
        ])
        XCTAssertEqual(noCarBaro, """
        Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Ambient Pressure (psi),Boost Press. (psi),Phone Pressure (psi)
        0,2400,50,14.29,11.8,14.286
        50,2450,51,14.29,13.3,14.286

        """)
        let carBaro = EngineLog.csv([EngineSample(time: 0, rpm: 2400, speedKmh: 50, baroKPa: 98, phoneBaroKPa: 98.5)])
        XCTAssertEqual(carBaro, "Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Ambient Pressure (psi),Phone Pressure (psi)\n"
                       + "0,2400,50,14.21,14.286\n")
    }

    func testWeatherColumnsUseTheNearestSnapshot() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = WeatherSnapshot(time: start, latitude: 39.74, longitude: -104.99, temperatureC: 10, humidity: 40,
                                windSpeedMPH: 6.24, windFromDeg: 230, pressureMSLhPa: 1013.3)
        let b = WeatherSnapshot(time: start.addingTimeInterval(600), latitude: 39.74, longitude: -104.99, temperatureC: 11,
                                humidity: 38, windSpeedMPH: 7, windFromDeg: 240)
        let csv = EngineLog.csv([EngineSample(time: 0, rpm: 900, speedKmh: 0), EngineSample(time: 500, rpm: 900, speedKmh: 0)],
                                weather: [b, a], start: start)
        XCTAssertEqual(csv, """
        Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Weather Humidity (%),Weather Wind (MPH),Weather Wind From (deg),Weather Air Temp (F),Weather Sea-Level Pressure (hPa)
        0,900,0,40,6.2,230,50.0,1013.3
        500000,900,0,38,7.0,240,51.8,

        """)
        // No start time or no snapshots: no weather columns.
        XCTAssertFalse(EngineLog.csv([EngineSample(time: 0, rpm: 900, speedKmh: 0)], weather: [a]).contains("Weather"))
    }

    func testWeatherColumnNamesStayClearOfTheDynosMatching() {
        // The dyno's parse() takes the first header matching these; the new columns must never be that first match.
        let names = ["Phone Pressure (psi)", "Weather Humidity (%)", "Weather Wind (MPH)", "Weather Wind From (deg)",
                     "Weather Air Temp (F)", "Weather Sea-Level Pressure (hPa)"]
        for n in names {
            for word in ["time", "rpm", "engine speed", "speed", "ambient", "baro", "boost", "pedal", "throttle"] {
                XCTAssertFalse(n.lowercased().contains(word), "\(n) contains \(word)")
            }
        }
    }

    func testGPXCarriesTheBarometer() {
        let t = Date(timeIntervalSince1970: 1_791_651_903)
        let gpx = GPX.document([TrackPoint(time: t, latitude: 1, longitude: 2, relativeAltitude: -1.234, pressure: 985.12)],
                               name: "x")
        XCTAssertTrue(gpx.contains("xmlns:dl=\"https://dynologger.turboloser.co/gpx/1\""))
        XCTAssertTrue(gpx.contains("<dl:relalt>-1.23</dl:relalt><dl:pressure>985.12</dl:pressure></trkpt>"))
    }

    func testOpenMeteoURLRoundsTheLocation() {
        let url = OpenMeteo.currentURL(latitude: 39.739236, longitude: -104.990251)!.absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
        XCTAssertTrue(url.contains("latitude=39.74&longitude=-104.99&"))
        XCTAssertTrue(url.contains("current=temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,pressure_msl"))
        XCTAssertFalse(url.contains("39.739"))
        XCTAssertNil(OpenMeteo.currentURL(latitude: .nan, longitude: 0))
    }

    func testOpenMeteoCurrentParses() throws {
        let json = """
        {"latitude":39.74,"longitude":-104.99,"elevation":1608.0,"current_units":{"time":"iso8601"},
         "current":{"time":"2026-11-18T06:15","interval":900,"temperature_2m":3.4,"relative_humidity_2m":61,
                    "wind_speed_10m":5.8,"wind_direction_10m":204,"pressure_msl":1019.6}}
        """
        let w = try OpenMeteo.parseCurrent(Data(json.utf8))
        XCTAssertEqual(w.time, Date(timeIntervalSince1970: 1_794_982_500))
        XCTAssertEqual(w.humidity, 61)
        XCTAssertEqual(w.windSpeedMPH, 5.8)
        XCTAssertEqual(w.windFromDeg, 204)
        XCTAssertEqual(w.temperatureC, 3.4)
        XCTAssertEqual(w.pressureMSLhPa, 1019.6)
        XCTAssertThrowsError(try OpenMeteo.parseCurrent(Data("{\"error\":true}".utf8)))
        let partial = try OpenMeteo.parseCurrent(Data("""
        {"latitude":1,"longitude":2,"current":{"time":"2026-11-18T06:15","relative_humidity_2m":50,"pressure_msl":null}}
        """.utf8))
        XCTAssertNil(partial.pressureMSLhPa)
        XCTAssertEqual(partial.humidity, 50)
    }

    func testSessionJSONFrom1_0StillDecodes() throws {
        let old = """
        {"vehicle":"Golf R","start":"2026-10-10T17:05:03Z","end":"2026-10-10T17:06:03Z","engineRows":10,"trackPoints":5,
         "goProRecorded":false}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(SessionSummary.self, from: Data(old.utf8))
        XCTAssertEqual(s.weather, [])
        XCTAssertFalse(s.phoneBarometer)
    }
}
