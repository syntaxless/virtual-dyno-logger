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

final class VehicleProfileTests: XCTestCase {
    func testWeightTakesOffMissingFuel() {
        let p = VehicleProfile(curbWeightLb: 3300, driverCargoLb: 200, tankGallons: 14.5)
        XCTAssertEqual(p.weightLb(fuelPercent: 100)!, 3300, accuracy: 1e-9)
        XCTAssertEqual(p.weightLb(fuelPercent: 50)!, 3300 - 7.25 * 6.1, accuracy: 1e-9)
        XCTAssertEqual(p.weightLb(fuelPercent: nil)!, 3300, accuracy: 1e-9)
        XCTAssertEqual(VehicleProfile(curbWeightLb: 3300).weightLb(fuelPercent: 20)!, 3300, accuracy: 1e-9)   // no tank size
        XCTAssertNil(VehicleProfile(driverCargoLb: 200).weightLb(fuelPercent: 50))
    }

    func testSanitizedDropsTypos() {
        let p = VehicleProfile(curbWeightLb: 33000, driverCargoLb: 200, tankGallons: 0, dragCoefficient: 32, frontalAreaM2: 2.2).sanitized()
        XCTAssertEqual(p, VehicleProfile(driverCargoLb: 200, frontalAreaM2: 2.2))
    }

    func testProfileAndFuelColumns() {
        let p = VehicleProfile(curbWeightLb: 3300, driverCargoLb: 200, tankGallons: 14.5, dragCoefficient: 0.32, frontalAreaM2: 2.2)
        let csv = EngineLog.csv([EngineSample(time: 0, rpm: 900, speedKmh: 0, fuelPercent: 50),
                                 EngineSample(time: 0.05, rpm: 900, speedKmh: 0)], vehicle: p)
        XCTAssertEqual(csv, """
        Time (msec),Engine Speed (RPM),Vehicle Speed (km/h),Fuel Level (%),Curb Weight (lbs),Driver + Cargo (lbs),Drag Coefficient,Frontal Area (m2)
        0,900,0,50.0,3256,200,0.320,2.20
        50,900,0,50.0,3256,200,0.320,2.20

        """)
        XCTAssertEqual(EngineLog.csv([EngineSample(time: 0, rpm: 900, speedKmh: 0)], vehicle: VehicleProfile()),
                       "Time (msec),Engine Speed (RPM),Vehicle Speed (km/h)\n0,900,0\n")
    }

    func testFuelLevelPID() {
        XCTAssertEqual(OBDPID.fuelLevel.decode([0x80]), 128 * 100 / 255, accuracy: 1e-9)
        XCTAssertEqual(ELM327.parse("412F80\r>")[.fuelLevel]!, 128 * 100 / 255, accuracy: 1e-9)
    }
}

final class RunCheckTests: XCTestCase {
    /// A run at 20 Hz: cruise at 75 MPH, coast with the clutch in (or in gear) to 30 MPH, cruise back up, and a 4th-gear pull.
    /// heading: 90 (east) or 270 (west) for the GPS track. brakeAt: seconds into the coast when hard braking starts.
    private func run(t0: Double = 0, heading: Double = 90, clutch: Bool = true, coastTo: Double = 30, brakeAt: Double? = nil,
                     pull: Bool = true, shift: Bool = false) -> (engine: [EngineSample], track: [TrackPoint]) {
        let mph = RunCheck.mph, k = 2400 / (50 * mph)   // RPM per m/s in the coasting gear
        var e: [EngineSample] = [], tr: [TrackPoint] = []
        var t = t0, v = 75 * mph, x = 0.0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func add(_ rpm: Double, _ pedal: Double) {
            e.append(EngineSample(time: t, rpm: rpm, speedKmh: (v * 3.6).rounded(), pedalRaw: pedal))
            let dir = heading == 90 ? 1.0 : -1.0
            tr.append(TrackPoint(time: start.addingTimeInterval(t), latitude: 39.74, longitude: -104.98 + dir * x / 85_000 + (dir < 0 ? 0.03 : 0)))
            t += 0.05
        }
        for _ in 0..<60 { add(k * v, 20); x += v * 0.05 }                       // 3 s cruise
        let lift = t, rpm0 = k * v
        while v > coastTo * mph {                                                // the coast
            let el = t - lift
            let rpm = clutch ? 850 + (rpm0 - 850) * exp(-max(0, el - 0.15) / 0.8) : k * v
            add(rpm, 15)
            let brake = brakeAt.map { el > $0 } ?? false
            v -= 0.05 * (0.000264 * v * v + 0.012 * 9.81 + (clutch ? 0 : 0.35) + (brake ? 3 : 0))
            x += v * 0.05
        }
        for _ in 0..<40 { add(k * v, 20) }                                       // back in gear
        if pull {
            var r = 2500.0, ratio = 2400 / (50 * mph) * 0.75, shifted = false
            v = r / ratio
            while r < 6800 {
                if shift && !shifted && r > 4500 { ratio *= 0.8; r = v * ratio; shifted = true }
                add(r, 80)
                v += 0.05 * 2.5; r = v * ratio
            }
            for _ in 0..<40 { add(v * ratio, 15); v -= 0.05 }
        }
        return (e, tr)
    }

    func testCleanCoastAndPull() {
        let (e, tr) = run()
        let sc = PedalScale(e.compactMap(\.pedalRaw))
        let c = RunCheck.coasts(e, scale: sc, track: tr, start: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.status, .good)
        XCTAssertGreaterThan(c.first!.fromMPH, 65)
        XCTAssertLessThan(c.first!.toMPH, 35)
        XCTAssertEqual(c.first!.heading!, 90, accuracy: 2)
        let p = RunCheck.pulls(e, scale: sc)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].good, "\(p[0])")
    }

    func testCoastInGearShortAndBraking() {
        var (e, _) = run(clutch: false, pull: false)
        var sc = PedalScale(low: 15, high: 80)
        XCTAssertEqual(RunCheck.coasts(e, scale: sc).first?.status, .inGear)
        (e, _) = run(coastTo: 60, pull: false)
        sc = PedalScale(low: 15, high: 80)
        XCTAssertEqual(RunCheck.coasts(e, scale: sc).first?.status, .short)
        (e, _) = run(brakeAt: 12, pull: false)
        let braked = RunCheck.coasts(e, scale: sc)
        XCTAssertEqual(braked.first?.status, .short)       // cut at the brakes, so it is too short
        XCTAssertLessThan(braked.first!.duration, 13)
    }

    func testShiftInThePull() {
        let (e, _) = run(shift: true)
        let p = RunCheck.pulls(e, scale: PedalScale(low: 15, high: 80))
        XCTAssertFalse(p.isEmpty)
        XCTAssertFalse(p[0].oneGear)
        XCTAssertFalse(p[0].good)
    }

    func testGuideAsksForTheOtherDirection() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = run(heading: 90, pull: false)
        var g = RunGuide(pulls: [], coasts: RunCheck.coasts(a.engine, scale: PedalScale(low: 15, high: 80), track: a.track, start: start))
        XCTAssertEqual(g.next, .coastTwo)
        XCTAssertTrue(g.prompt.hasPrefix("Coast 2"))
        let b = run(t0: 200, heading: 270)
        let e = a.engine + b.engine, tr = a.track + b.track, sc = PedalScale(e.compactMap(\.pedalRaw))
        g = RunGuide(pulls: RunCheck.pulls(e, scale: sc), coasts: RunCheck.coasts(e, scale: sc, track: tr, start: start))
        XCTAssertTrue(g.hasPair)
        XCTAssertNil(g.next)
        XCTAssertEqual(RunGuide(pulls: [], coasts: [], wantCoasts: false).next, .pull)
        XCTAssertEqual(RunCheck.bearing(0, 0, 0, 1), 90, accuracy: 1e-6)
    }
}

final class AccessportMergeTests: XCTestCase {
    private func rpm(_ t: Double) -> Double { 2500 + 900 * sin(t / 7) + 400 * sin(t / 2.3 + 1) + (t > 60 && t < 70 ? (t - 60) * 400 : 0) }
    private func kmh(_ t: Double) -> Double { 80 + 20 * sin(t / 11) + 10 * sin(t / 3.7 + 2) }

    /// An OBD log of 120 s at 10 Hz in the app's format, and an Accessport log at 15 Hz that started `lag` s into the run.
    private func logs(lag: Double, apAmbient: Bool = false) -> (obd: String, ap: String) {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = stride(from: 0.0, to: 120, by: 0.1).map { t in
            EngineSample(time: t, rpm: rpm(t), speedKmh: kmh(t), pedalRaw: 20, mapKPa: 100, baroKPa: t < 1 ? 98 : nil,
                         ambientC: t < 1 ? 21 : nil, phoneBaroKPa: 98.4 - t * 0.001, fuelPercent: t < 1 ? 50 : nil)
        }
        let wx = [WeatherSnapshot(time: start, latitude: 1, longitude: 2, temperatureC: 20, humidity: 45, windSpeedMPH: 5, windFromDeg: 90)]
        let obd = EngineLog.csv(samples, weather: wx, start: start, vehicle: VehicleProfile(curbWeightLb: 3300, driverCargoLb: 200))
        var ap = "Time (sec),Engine Speed (RPM),Vehicle Speed (mph),Accel. Pedal Position (%),Boost Press. (psi)"
            + (apAmbient ? ",Ambient Air Temp (F)" : "") + "\n"
        for t in stride(from: 0.0, to: 80, by: 1.0 / 15) {
            let s = t + lag
            ap += String(format: "%.3f,%.0f,%.0f,%.1f,%.1f", t, rpm(s), kmh(s) / 1.609344, 25.0, 24.6) + (apAmbient ? ",68.0" : "") + "\n"
        }
        return (obd, ap)
    }

    func testLinesUpOnRPMAndAppendsTheAppsColumns() throws {
        let (obd, ap) = logs(lag: 23.4)
        let r = try AccessportMerge.merge(accessport: ap, obdLog: obd)
        XCTAssertEqual(r.method, .rpm)
        XCTAssertEqual(r.offset, 23.4, accuracy: 0.06)
        XCTAssertEqual(r.rows, 1200)
        for h in ["Ambient Air Temp (F)", "Ambient Pressure (psi)", "Phone Pressure (psi)", "Weather Humidity (%)", "Fuel Level (%)",
                  "Curb Weight (lbs)", "Driver + Cargo (lbs)"] {
            XCTAssertTrue(r.added.contains(h), h)
        }
        for h in r.added { XCTAssertFalse(AccessportMerge.replaced(h), h) }
        let lines = r.csv.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("Time (sec),Engine Speed (RPM),Vehicle Speed (mph),Accel. Pedal Position (%),Boost Press. (psi),"))
        XCTAssertTrue(lines[1].hasPrefix("0.000,"))     // the Accessport's own rows, unchanged
        XCTAssertTrue(lines[1].contains(",24.6,"))
        XCTAssertTrue(lines[1].contains(",45,"))        // weather carried in
        XCTAssertEqual(lines.count, 1201)
    }

    func testKeepsTheAccessportsOwnAmbientColumn() throws {
        let (obd, ap) = logs(lag: 5, apAmbient: true)
        let r = try AccessportMerge.merge(accessport: ap, obdLog: obd)
        XCTAssertFalse(r.added.contains("Ambient Air Temp (F)"))
        XCTAssertTrue(r.added.contains("Ambient Pressure (psi)"))
    }

    func testLinesUpOnGPSSpeedWithoutOBD() throws {
        let (_, ap) = logs(lag: 41.0)
        let track = stride(from: 0.0, to: 150, by: 0.2).map { (time: $0, speed: kmh($0) / 3.6) }
        let r = try AccessportMerge.merge(accessport: ap, obdLog: nil, track: track)
        XCTAssertEqual(r.method, .speed)
        XCTAssertEqual(r.offset, 41.0, accuracy: 0.6)    // whole-MPH speed lines up less tightly than RPM
    }

    func testRejectsAFileThatIsNotALog() {
        XCTAssertThrowsError(try AccessportMerge.merge(accessport: "a,b\n1,2\n", obdLog: nil)) {
            XCTAssertEqual($0 as? AccessportMerge.MergeError, .notAccessport)
        }
    }
}
