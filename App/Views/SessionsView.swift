import DynoLoggerCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var importing = false
    @State private var attachMessage: String?
    @State private var attachFailed = false
    let session: StoredSession

    private var current: StoredSession { store.sessions.first { $0.id == session.id } ?? session }

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

            Panel(title: "Accessport") {
                if let a = current.summary?.accessport {
                    Text("\(a.file) is merged into the log: its RPM, speed, pedal and boost, with this run's weather, barometer, "
                         + "fuel and weight columns added. " + lineUp(a))
                        .font(.vtSmall).foregroundStyle(Phosphor.mut)
                    Button("Take the Accessport log off") {
                        try? SessionFiles.detachAccessport(from: session.folder)
                        store.reload()
                        attachMessage = nil
                    }
                    .buttonStyle(BracketButtonStyle())
                } else {
                    Text("Logged this run with a Cobb Accessport too? Copy the log off it (Accessport Manager, or the AP's USB) "
                         + "to Files, then attach it. Its boost is the car's own sensor, which OBD-II can't read past about 23 psi.")
                        .font(.vtSmall).foregroundStyle(Phosphor.mut)
                }
                Button(current.summary?.accessport == nil ? "Attach Accessport log" : "Attach a different log") { importing = true }
                    .buttonStyle(BracketButtonStyle())
                if let m = attachMessage { PromptLine(text: m, color: attachFailed ? Phosphor.err : Phosphor.amber) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .data]) { result in
                attach(result)
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

    private func lineUp(_ a: SessionSummary.AttachedLog) -> String {
        switch a.method {
        case .rpm: return String(format: "Lined up with the OBD-II log by RPM (%+.2f s, within %.0f RPM on average).", a.offset, a.matchError ?? 0)
        case .speed: return String(format: "Lined up with the GPS track by speed (%+.1f s).", a.offset)
        case .start: return "Nothing to line it up with, so it is taken to start with the run."
        }
    }

    private func attach(_ result: Result<URL, Error>) {
        attachFailed = false
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let r = try SessionFiles.attachAccessport(text, fileName: url.lastPathComponent, to: session.folder)
            store.reload()
            attachMessage = "Attached: \(r.rows) rows, \(r.added.count) columns added from this run."
        } catch let e as AccessportMerge.MergeError {
            attachFailed = true
            switch e {
            case .notAccessport: attachMessage = "That file has no Time and Engine Speed (RPM) columns. Pick the Accessport's .csv datalog."
            case .tooShort: attachMessage = "That log is too short to use."
            case .noMatch: attachMessage = "That log doesn't line up with this run's RPM or speed. Is it from the same drive?"
            }
        } catch {
            attachFailed = true
            attachMessage = "Could not read that file: \(error.localizedDescription)"
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
