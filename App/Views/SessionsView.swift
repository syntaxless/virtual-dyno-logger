import DynoLoggerCore
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: SessionStore
    static let dyno = URL(string: "https://dyno.turboloser.co/")!

    var body: some View {
        NavigationStack {
            TerminalScreen(path: "logger/runs", command: "ls -t Sessions/", status: "\(store.sessions.count) runs") {
                if store.sessions.isEmpty {
                    PromptLine(text: "No runs yet. Record one on the Record tab and it shows up here.")
                }
                ForEach(store.sessions) { s in
                    NavigationLink(value: s) { row(s) }
                        .buttonStyle(RunRowStyle())
                        .contextMenu {
                            Button(role: .destructive) { store.delete(s) } label: { Label("Delete Run", systemImage: "trash") }
                        }
                }
                if !store.sessions.isEmpty {
                    PromptLine(text: "Tap a run to share its files with the Virtual Dyno. Touch and hold to delete.")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: StoredSession.self) { SessionDetail(session: $0) }
            .onAppear { store.reload() }
        }
    }

    private func row(_ s: StoredSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            (Text("> ").foregroundColor(Phosphor.fg) + Text(s.name).foregroundColor(Phosphor.hi))
                .font(.vtBody)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(caption(s)).font(.vtSmall).foregroundStyle(Phosphor.mut)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ s: StoredSession) -> String {
        guard let m = s.summary else { return "" }
        let secs = Int(m.end.timeIntervalSince(m.start))
        return "\(secs / 60):\(String(format: "%02d", secs % 60)) · \(m.engineRows) OBD rows · \(m.trackPoints) GPS points"
            + (m.goProRecorded ? " · video" : "")
    }
}

/// The page's upload boxes: a dashed border that lights up green when pressed.
private struct RunRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(configuration.isPressed ? Phosphor.fg.opacity(0.1) : .clear)
            .overlay(Rectangle().strokeBorder(configuration.isPressed ? Phosphor.fg : Phosphor.dim,
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
    }
}

struct SessionDetail: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    let session: StoredSession

    var body: some View {
        TerminalScreen(path: "logger/runs", command: "cd \(session.name)") {
            Panel(title: "Files") {
                if let log = session.engineLog {
                    ShareLink(item: log) { fileLabel(log, box: "Cobb Accessport log") }.buttonStyle(.plain)
                }
                if let gpx = session.track {
                    ShareLink(item: gpx) { fileLabel(gpx, box: "RaceBox, Dragy or GPX") }.buttonStyle(.plain)
                }
                Text("Share a file, or pick it from the Files app (On My iPhone > Dyno Logger > Sessions) in the dyno's upload box.")
                    .font(.vtCaption).foregroundStyle(Phosphor.mut)
            }

            Link(destination: SessionsView.dyno) { Text("Open the Virtual Dyno") }
                .buttonStyle(BracketButtonStyle())

            if let m = session.summary {
                Panel(title: "Details") {
                    detail("Started", m.start.formatted(date: .abbreviated, time: .standard))
                    if let a = m.obdAdapter { detail("OBD-II", a) }
                    if let g = m.trackSource { detail("GPS", g) }
                    if let p = m.pedalSource { detail("Pedal from", p == .pedal ? "Accelerator pedal" : "Throttle") }
                    detail("GoPro", m.goProRecorded ? "Recorded" : "Not used")
                }
            }

            Button("Delete run", role: .destructive) { confirmDelete = true }
                .buttonStyle(BracketButtonStyle(color: Phosphor.err))
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete \(session.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(session); dismiss() }
        } message: {
            Text("Its log, GPS track and details are removed from this iPhone.")
        }
    }

    private func fileLabel(_ url: URL, box: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                (Text("> ").foregroundColor(Phosphor.fg) + Text(url.lastPathComponent).foregroundColor(Phosphor.hi))
                    .lineLimit(1).truncationMode(.middle)
                Text("for the dyno's \"\(box)\" box").font(.vtSmall).foregroundStyle(Phosphor.mut)
            }
            Spacer(minLength: 8)
            Image(systemName: "square.and.arrow.up").foregroundStyle(Phosphor.fg)
        }
        .font(.vtBody)
        .padding(10)
        .overlay(Rectangle().strokeBorder(Phosphor.dim, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
    }

    private func detail(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Phosphor.mut)
            Spacer()
            Text(v).foregroundStyle(Phosphor.hi).multilineTextAlignment(.trailing)
        }
        .font(.vtBody)
        .accessibilityElement(children: .combine)
    }
}
