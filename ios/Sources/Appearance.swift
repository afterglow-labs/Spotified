import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case afterglow, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var background: Color { Color(hex: self == .afterglow ? 0x120820 : 0xf0ebe3) }
    var panel: Color { Color(hex: self == .afterglow ? 0x241237 : 0xfaf6f0) }
    var foreground: Color { Color(hex: self == .afterglow ? 0xfff2e9 : 0x5a5248) }
    var accent: Color { Color(hex: self == .afterglow ? 0xff8000 : 0xa65b38) }
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
            .scrollContentBackground(.hidden).background(theme.background)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.scheme, for: .navigationBar)
    }
}
extension View { func appSurface() -> some View { modifier(AppSurface()) } }

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
