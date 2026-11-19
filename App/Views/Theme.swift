import SwiftUI
import UIKit

/// The Virtual Dyno web app's look (dyno.turboloser.co, syntaxless/virtual-dyno index.html): a green phosphor CRT
/// terminal in VT323. The colors are the page's default ("green") theme tokens, with the same names.
enum Phosphor {
    static let desk = Color(hex: 0x010503)     // behind the window
    static let bg = Color(hex: 0x030F08)       // the window
    static let screen = Color(hex: 0x020B06)
    static let fg = Color(hex: 0x46F08A)       // main green: text, power line
    static let hi = Color(hex: 0xD6FFE6)       // bright text, values
    static let mut = Color(hex: 0x37B46C)      // muted text
    static let dim = Color(hex: 0x1C7A45)      // borders
    static let faint = Color(hex: 0x0E3D22)
    static let amber = Color(hex: 0xFFB938)    // --s2: torque, measured values
    static let cyan = Color(hex: 0x59E4FF)     // --s3: wheel power
    static let pink = Color(hex: 0xFF7AD9)     // --s4: boost
    static let err = Color(hex: 0xFF6B5E)
    static let ink = Color(hex: 0x02100A)      // text on a green bar
    static let halo = Color(hex: 0x08240F)

    static let uiDesk = UIColor(red: 1 / 255, green: 5 / 255, blue: 3 / 255, alpha: 1)
    static let uiFg = UIColor(red: 0x46 / 255, green: 0xF0 / 255, blue: 0x8A / 255, alpha: 1)
    static let uiHi = UIColor(red: 0xD6 / 255, green: 0xFF / 255, blue: 0xE6 / 255, alpha: 1)
    static let uiDim = UIColor(red: 0x1C / 255, green: 0x7A / 255, blue: 0x45 / 255, alpha: 1)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension Font {
    /// VT323 (bundled, SIL OFL). It runs small next to system fonts, so sizes are larger than usual: the web page's
    /// body text is 22px. It scales with Dynamic Type.
    static func vt(_ size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("VT323-Regular", size: size, relativeTo: style)
    }
    static let vtBody = vt(22)
    static let vtSmall = vt(19, relativeTo: .footnote)
    static let vtCaption = vt(17, relativeTo: .caption)
}

extension View {
    /// The phosphor glow the page puts on its text (text-shadow 0 0 5px).
    func glow(_ c: Color = Phosphor.fg, radius: CGFloat = 3, opacity: Double = 0.45) -> some View {
        shadow(color: c.opacity(opacity), radius: radius)
    }
}

/// Global UIKit styling for the bars SwiftUI does not let us style directly.
enum Appearance {
    static func apply() {
        let font = { (s: CGFloat) in UIFont(name: "VT323-Regular", size: s) ?? .monospacedSystemFont(ofSize: s * 0.7, weight: .regular) }

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = Phosphor.uiDesk
        tab.shadowColor = Phosphor.uiDim
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = Phosphor.uiDim
            item.normal.titleTextAttributes = [.font: font(15), .foregroundColor: Phosphor.uiDim]
            item.selected.iconColor = Phosphor.uiFg
            item.selected.titleTextAttributes = [.font: font(15), .foregroundColor: Phosphor.uiFg]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = Phosphor.uiDesk
        nav.shadowColor = Phosphor.uiDim
        nav.titleTextAttributes = [.font: font(24), .foregroundColor: Phosphor.uiHi]
        nav.largeTitleTextAttributes = [.font: font(40), .foregroundColor: Phosphor.uiHi]
        let button = UIBarButtonItemAppearance()
        button.normal.titleTextAttributes = [.font: font(22), .foregroundColor: Phosphor.uiFg]
        nav.buttonAppearance = button
        nav.backButtonAppearance = button
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = Phosphor.uiFg
    }
}

// MARK: - Building blocks

/// One screen: the page's terminal window. A green title bar ("trbo@losr: ~/logger"), the prompt line, then the content,
/// over the dark screen with the page's halo and scanlines.
struct TerminalScreen<Content: View>: View {
    let path: String
    let command: String
    var status: String?
    var statusColor: Color = Phosphor.ink
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("trbo@losr: ~/\(path)")
                Spacer()
                if let status { Text(status).foregroundStyle(statusColor) }
            }
            .font(.vt(21))
            .tracking(1)
            .foregroundStyle(Phosphor.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
            .background(Phosphor.fg)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    (Text("trbo@losr:~$ ").foregroundColor(Phosphor.mut) + Text(command).foregroundColor(Phosphor.hi))
                        .font(.vtBody)
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Phosphor.fg)
        .font(.vtBody)
        .background(CRTBackground())
    }
}

/// The page's screen: dark green with a soft halo at the top, scanlines and a vignette.
struct CRTBackground: View {
    var body: some View {
        ZStack {
            Phosphor.bg
            RadialGradient(colors: [Phosphor.halo, .clear], center: .top, startRadius: 0, endRadius: 520)
            Canvas { ctx, size in
                var y: CGFloat = 2
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.17)))
                    y += 3
                }
            }
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 260, endRadius: 700)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The page's fieldset: a thin border with its title cut into the top edge.
struct Panel<Content: View>: View {
    let title: String
    var color: Color = Phosphor.dim
    var titleColor: Color = Phosphor.hi
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(Rectangle().stroke(color, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.vtBody)
                    .foregroundStyle(titleColor)
                    .padding(.horizontal, 8)
                    .background(Phosphor.bg)
                    .offset(x: 10, y: -12)
            }
            .padding(.top, 6)
    }
}

/// The result tiles: a big glowing number in one color, its unit and caption in the same color.
struct StatTile: View {
    let title: String
    let value: String?
    let unit: String
    var color: Color = Phosphor.fg
    var size: CGFloat = 64

    var body: some View {
        Panel(title: title, color: color, titleColor: color) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value ?? "–")
                    .font(.vt(size, relativeTo: .largeTitle))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .glow(color, radius: 7, opacity: 0.8)
                Text(unit).font(.vt(24))
            }
            .foregroundStyle(color)
        }
    }
}

/// The page's ".btn": "[ Label ]" in green, inverted while pressed.
struct BracketButtonStyle: ButtonStyle {
    var color: Color = Phosphor.fg
    func makeBody(configuration: Configuration) -> some View {
        BracketLabel(label: configuration.label, color: color, pressed: configuration.isPressed)
    }

    private struct BracketLabel<L: View>: View {
        let label: L
        let color: Color
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            HStack(spacing: 0) { Text("[ "); label; Text(" ]") }
                .font(.vtBody)
                .foregroundStyle(pressed ? Phosphor.ink : (enabled ? color : Phosphor.dim))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(pressed ? color : .clear)
        }
    }
}

/// A checkbox the way the page drew its old one: "[X] label".
struct BracketToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(configuration.isOn ? "[X]" : "[ ]").foregroundStyle(Phosphor.fg)
                configuration.label.foregroundStyle(Phosphor.mut)
                Spacer(minLength: 0)
            }
            .font(.vtBody)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

/// The page's text inputs: black box, dim border, bright text, green glow when focused.
extension View {
    func terminalField(focused: Bool) -> some View {
        self
            .font(.vtBody)
            .foregroundStyle(Phosphor.hi)
            .tint(Phosphor.fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black)
            .overlay(Rectangle().stroke(focused ? Phosphor.fg : Phosphor.dim, lineWidth: 1))
            .shadow(color: focused ? Phosphor.fg.opacity(0.5) : .clear, radius: 5)
    }
}

/// A "> message" line, like the page's status messages.
struct PromptLine: View {
    let text: String
    var color: Color = Phosphor.mut
    var body: some View {
        (Text("> ").foregroundColor(Phosphor.dim) + Text(text).foregroundColor(color))
            .font(.vtSmall)
            .fixedSize(horizontal: false, vertical: true)
    }
}
