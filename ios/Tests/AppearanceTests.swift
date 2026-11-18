import XCTest
@testable import Spotified

final class AppearanceTests: XCTestCase {
    func testDefaultAndRetiredThemeMigrateWithoutChangingLightPreference() throws {
        let suite = "Spotified.AppearanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppTheme.migrateSavedAppearance(in: defaults), .afterglow)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "afterglow")
        defaults.set("dark", forKey: "appearance")
        XCTAssertEqual(AppTheme.migrateSavedAppearance(in: defaults), .afterglow)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "afterglow")
        defaults.set("light", forKey: "appearance")
        XCTAssertEqual(AppTheme.migrateSavedAppearance(in: defaults), .light)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
        XCTAssertEqual(AppTheme.allCases.map(\.rawValue), ["afterglow", "light"])
    }
}
