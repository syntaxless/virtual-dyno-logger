import SwiftUI

struct ContentView: View {
    enum Tab: String { case record, runs, devices, about }
    @State private var tab: Tab = Demo.startTab.flatMap(Tab.init(rawValue:)) ?? .record

    var body: some View {
        TabView(selection: $tab) {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
                .tag(Tab.record)
            SessionsView()
                .tabItem { Label("Runs", systemImage: "folder") }
                .tag(Tab.runs)
            DevicesView()
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(Tab.devices)
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .tint(Phosphor.fg)
    }
}
