import SwiftUI

/// Version, the support site's pages (privacy policy, support), the dyno, and the font licence.
struct AboutView: View {
    static let site = URL(string: "https://virtualdynologger.turboloser.co/")!
    static let support = URL(string: "https://virtualdynologger.turboloser.co/support/")!
    static let privacy = URL(string: "https://virtualdynologger.turboloser.co/privacy/")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            TerminalScreen(path: "logger/about", command: "cat README", status: "v" + version) {
                Panel(title: "Virtual Dyno Logger") {
                    Text("Records a run from an OBD-II adapter, a GPS and a GoPro at the same time, and saves the two files "
                         + "the Virtual Dyno reads: a Cobb Accessport-style log and a GPX track.")
                        .foregroundStyle(Phosphor.mut)
                    Link(destination: SessionsView.dyno) { Text("Open the Virtual Dyno") }
                        .buttonStyle(BracketButtonStyle())
                }

                Panel(title: "Privacy") {
                    Text("No account, no ads, no analytics. Your runs stay on this iPhone until you share a file yourself.")
                        .foregroundStyle(Phosphor.mut)
                    Link(destination: Self.privacy) { Text("Privacy Policy") }.buttonStyle(BracketButtonStyle())
                }

                Panel(title: "Help") {
                    Link(destination: Self.support) { Text("Support") }.buttonStyle(BracketButtonStyle())
                    Link(destination: Self.site) { Text("virtualdynologger.turboloser.co") }.buttonStyle(BracketButtonStyle())
                }

                Panel(title: "Credits") {
                    NavigationLink { LicenseView() } label: { Text("VT323 font licence (SIL OFL 1.1)") }
                        .buttonStyle(BracketButtonStyle())
                    Text("Not affiliated with Cobb Tuning, RaceBox, Dragy or GoPro. Power figures are estimates.")
                        .font(.vtCaption).foregroundStyle(Phosphor.mut)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// The bundled font's licence, which the OFL asks to ship with the font.
private struct LicenseView: View {
    private var text: String {
        Bundle.main.url(forResource: "OFL", withExtension: "txt").flatMap { try? String(contentsOf: $0) }
            ?? "VT323 by Peter Hull, licensed under the SIL Open Font License 1.1."
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Phosphor.mut)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CRTBackground())
        .navigationTitle("VT323 Licence")
        .navigationBarTitleDisplayMode(.inline)
    }
}
