import DynoLoggerCore
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: SessionStore
    static let dyno = URL(string: "https://dyno.turboloser.co/")!

    var body: some View {
        NavigationStack {
            List {
                if store.sessions.isEmpty {
                    Text("Recorded runs appear here.").foregroundStyle(.secondary)
                }
                ForEach(store.sessions) { s in
                    NavigationLink(value: s) {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(caption(s)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in idx.map { store.sessions[$0] }.forEach(store.delete) }
            }
            .navigationTitle("Runs")
            .navigationDestination(for: StoredSession.self) { SessionDetail(session: $0) }
            .onAppear { store.reload() }
        }
    }

    private func caption(_ s: StoredSession) -> String {
        guard let m = s.summary else { return "" }
        let mins = Int(m.end.timeIntervalSince(m.start) / 60), secs = Int(m.end.timeIntervalSince(m.start)) % 60
        return "\(mins):\(String(format: "%02d", secs)) · \(m.engineRows) OBD rows · \(m.trackPoints) GPS points"
            + (m.goProRecorded ? " · video" : "")
    }
}

struct SessionDetail: View {
    let session: StoredSession

    var body: some View {
        List {
            Section {
                if let log = session.engineLog {
                    ShareLink(item: log) { Label(log.lastPathComponent, systemImage: "tablecells") }
                }
                if let gpx = session.track {
                    ShareLink(item: gpx) { Label(gpx.lastPathComponent, systemImage: "map") }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("In the Virtual Dyno, load the .csv into \"Cobb Accessport log\" and the .gpx into \"RaceBox, Dragy or GPX\". "
                     + "Both are in the Files app under On My iPhone > Dyno Logger > Sessions.")
            }
            Section {
                Link(destination: SessionsView.dyno) { Label("Open the Virtual Dyno", systemImage: "gauge.with.dots.needle.67percent") }
            }
            if let m = session.summary {
                Section("Details") {
                    LabeledContent("Started", value: m.start.formatted(date: .abbreviated, time: .standard))
                    if let a = m.obdAdapter { LabeledContent("OBD-II", value: a) }
                    if let g = m.trackSource { LabeledContent("GPS", value: g) }
                    if let p = m.pedalSource { LabeledContent("Pedal from", value: p == .pedal ? "Accelerator pedal" : "Throttle") }
                    LabeledContent("GoPro", value: m.goProRecorded ? "Recorded" : "Not used")
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
