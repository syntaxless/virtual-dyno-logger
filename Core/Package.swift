// swift-tools-version:5.9
// DynoLoggerCore holds everything that does not need an iPhone: the file writers the Virtual Dyno reads,
// the ELM327/OBD-II decoder, the NMEA and RaceBox GPS decoders and the GoPro BLE command bytes.
// The iOS app (App/, built from project.yml) links it. `swift test` runs on any Mac.
import PackageDescription

let package = Package(
    name: "DynoLoggerCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "DynoLoggerCore", targets: ["DynoLoggerCore"])],
    targets: [
        .target(name: "DynoLoggerCore"),
        .testTarget(name: "DynoLoggerCoreTests", dependencies: ["DynoLoggerCore"]),
    ]
)
