import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            SessionsView()
                .tabItem { Label("Runs", systemImage: "folder") }
            DevicesView()
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .tint(.green)
    }
}
