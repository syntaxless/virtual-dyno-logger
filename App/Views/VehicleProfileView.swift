import DynoLoggerCore
import SwiftUI

/// Weight and drag for one vehicle, typed once and written into every run's log so the dyno fills them in.
struct VehicleProfileView: View {
    let vehicle: String
    @Environment(\.dismiss) private var dismiss
    @State private var curb = ""
    @State private var load = ""
    @State private var tank = ""
    @State private var cd = ""
    @State private var area = ""
    @FocusState private var focus: Field?

    private enum Field { case curb, load, tank, cd, area }

    var body: some View {
        TerminalScreen(path: "logger/vehicle", command: "edit \(vehicle.isEmpty ? "vehicle" : vehicle)") {
            Panel(title: "Weight") {
                field("Curb weight (lb), with a full tank", $curb, .curb, "e.g. 3,300")
                field("Driver, passengers and cargo (lb)", $load, .load, "e.g. 200")
                field("Fuel tank (US gal)", $tank, .tank, "e.g. 14.5")
                Text("The car's fuel level takes off the fuel that is not in the tank, about 6.1 lb a gallon. "
                     + "Weight matters most: the dyno's drag and rolling resistance from a coast are only as good as it is.")
                    .font(.vtCaption).foregroundStyle(Phosphor.mut)
            }
            Panel(title: "Drag (optional)") {
                field("Drag coefficient (Cd)", $cd, .cd, "e.g. 0.32")
                field("Frontal area (m²)", $area, .area, "e.g. 2.2")
                Text("Leave these empty to let the dyno use its own or to measure them from coasts.")
                    .font(.vtCaption).foregroundStyle(Phosphor.mut)
            }
            HStack(spacing: 12) {
                Button("Save") { save(); dismiss() }.buttonStyle(BracketButtonStyle())
                Button("Cancel") { dismiss() }.buttonStyle(BracketButtonStyle())
            }
        }
        .onAppear(perform: loadProfile)
    }

    private func field(_ title: String, _ text: Binding<String>, _ f: Field, _ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.vtSmall).foregroundStyle(Phosphor.hi)
            TextField("", text: text, prompt: Text(prompt).foregroundColor(Phosphor.mut))
                .keyboardType(.decimalPad)
                .focused($focus, equals: f)
                .terminalField(focused: focus == f)
        }
    }

    private func num(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        return t.isEmpty ? nil : Double(t)
    }

    private func show(_ x: Double?) -> String {
        x.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
    }

    private func loadProfile() {
        let p = VehicleProfiles.profile(for: vehicle) ?? VehicleProfile()
        curb = show(p.curbWeightLb); load = show(p.driverCargoLb); tank = show(p.tankGallons)
        cd = show(p.dragCoefficient); area = show(p.frontalAreaM2)
    }

    private func save() {
        VehicleProfiles.save(VehicleProfile(curbWeightLb: num(curb), driverCargoLb: num(load), tankGallons: num(tank),
                                            dragCoefficient: num(cd), frontalAreaM2: num(area)).sanitized(), for: vehicle)
    }
}
