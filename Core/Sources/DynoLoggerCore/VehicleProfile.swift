import Foundation

/// What the person types once per vehicle in the app, so the dyno does not have to be told again: weight, and drag if
/// they know it. A coast-down measures drag only relative to mass, so the weight here is what makes a fitted drag
/// number mean anything. Every field is optional; an empty one is simply not written.
public struct VehicleProfile: Codable, Equatable, Sendable {
    /// Curb weight with a full tank, lb. That is what US specifications give (SAE J1100).
    public var curbWeightLb: Double?
    /// Driver, passengers and cargo, lb.
    public var driverCargoLb: Double?
    /// Fuel tank size, US gallons. With the car's fuel level, it takes off the fuel that is not in the tank.
    public var tankGallons: Double?
    public var dragCoefficient: Double?
    public var frontalAreaM2: Double?

    /// Gasoline, about 0.73 kg per litre.
    public static let fuelLbPerGallon = 6.1

    public init(curbWeightLb: Double? = nil, driverCargoLb: Double? = nil, tankGallons: Double? = nil,
                dragCoefficient: Double? = nil, frontalAreaM2: Double? = nil) {
        self.curbWeightLb = curbWeightLb
        self.driverCargoLb = driverCargoLb
        self.tankGallons = tankGallons
        self.dragCoefficient = dragCoefficient
        self.frontalAreaM2 = frontalAreaM2
    }

    public var isEmpty: Bool {
        curbWeightLb == nil && driverCargoLb == nil && tankGallons == nil && dragCoefficient == nil && frontalAreaM2 == nil
    }

    /// The car's weight at a fuel level (%): the full-tank curb weight less the missing fuel. With no fuel level or no
    /// tank size, the curb weight as typed.
    public func weightLb(fuelPercent: Double?) -> Double? {
        guard let curb = curbWeightLb else { return nil }
        guard let f = fuelPercent, let tank = tankGallons, f.isFinite, tank > 0 else { return curb }
        return curb - (1 - min(100, max(0, f)) / 100) * tank * Self.fuelLbPerGallon
    }

    /// Keeps only believable values, so a typo does not reach the dyno (the dyno checks its own ranges too).
    public func sanitized() -> VehicleProfile {
        func r(_ x: Double?, _ lo: Double, _ hi: Double) -> Double? { x.flatMap { $0.isFinite && $0 >= lo && $0 <= hi ? $0 : nil } }
        return VehicleProfile(curbWeightLb: r(curbWeightLb, 500, 15000), driverCargoLb: r(driverCargoLb, 0, 3000),
                              tankGallons: r(tankGallons, 1, 60), dragCoefficient: r(dragCoefficient, 0.1, 1.5),
                              frontalAreaM2: r(frontalAreaM2, 0.5, 8))
    }
}
