import DynoLoggerCore
import Foundation

struct StoredSession: Identifiable, Hashable {
    let folder: URL
    let summary: SessionSummary?
    let engineLog: URL?
    let track: URL?
    var id: URL { folder }
    var name: String { folder.lastPathComponent }

    static func == (a: StoredSession, b: StoredSession) -> Bool { a.folder == b.folder }
    func hash(into h: inout Hasher) { h.combine(folder) }
}

/// The saved runs, one folder each under Documents/Sessions (visible in the Files app).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [StoredSession] = []

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }()

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        sessions = folders.filter(\.hasDirectoryPath).map { f in
            let files = (try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? []
            let summary = (try? Data(contentsOf: f.appendingPathComponent("session.json")))
                .flatMap { try? dec.decode(SessionSummary.self, from: $0) }
            return StoredSession(folder: f, summary: summary,
                                 engineLog: files.first { $0.pathExtension == "csv" },
                                 track: files.first { $0.pathExtension == "gpx" })
        }
        .sorted { ($0.summary?.start ?? .distantPast) > ($1.summary?.start ?? .distantPast) }
    }

    func delete(_ s: StoredSession) {
        try? FileManager.default.removeItem(at: s.folder)
        reload()
    }
}
