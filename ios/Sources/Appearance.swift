import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case afterglow, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var background: Color { Color(hex: self == .afterglow ? 0x120820 : 0xf0ebe3) }
    var panel: Color { Color(hex: self == .afterglow ? 0x241237 : 0xfaf6f0) }
    var foreground: Color { Color(hex: self == .afterglow ? 0xfff2e9 : 0x5a5248) }
    var accent: Color { Color(hex: self == .afterglow ? 0xff8000 : 0xa65b38) }
    var toggle: Color { self == .afterglow ? Color(hex: 0xa54764) : accent }
    var scheme: ColorScheme { self == .light ? .light : .dark }

    @discardableResult static func migrateSavedAppearance(in defaults: UserDefaults = .standard) -> AppTheme {
        let theme = AppTheme(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .afterglow
        defaults.set(theme.rawValue, forKey: "appearance")
        return theme
    }
}

extension Color {
    init(hex: Int) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = AppTheme.afterglow }
extension EnvironmentValues {
    var spotifiedTheme: AppTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } }
}
private struct AppSurface: ViewModifier {
    @Environment(\.spotifiedTheme) private var theme
    func body(content: Content) -> some View {
        content.foregroundStyle(theme.foreground).tint(theme.accent)
            .toggleStyle(SwitchToggleStyle(tint: theme.toggle))
            .scrollContentBackground(.hidden).background { AppBackdrop() }
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
    }
}
extension View { func appSurface() -> some View { modifier(AppSurface()) } }

private struct AppBackdrop: View {
    @Environment(\.spotifiedTheme) private var theme
    var body: some View {
        ZStack {
            theme.background
            if theme == .afterglow {
                // Match Odysseus's static native Afterglow surface.
                RadialGradient(colors: [Color.orange.opacity(0.13), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 470)
                RadialGradient(colors: [Color.purple.opacity(0.17), .clear], center: .bottomLeading,
                               startRadius: 0, endRadius: 500)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct VersionLabel: View {
    var body: some View {
        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("appVersion")
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).textSelection(.enabled).accessibilityIdentifier("serverError")
    }
}
